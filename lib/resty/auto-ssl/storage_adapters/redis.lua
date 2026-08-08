local redis = require "resty.redis"

local _M = {}

_M.certs_zlist = "certs_zset_store"

local function prefixed_key(self, key)
  if self.options["prefix"] then
    return self.options["prefix"] .. ":" .. key
  else
    return key
  end
end

function _M.new(auto_ssl_instance)
  local options = auto_ssl_instance:get("redis") or {}

  if not options["host"] then
    options["host"] = "127.0.0.1"
  end

  if not options["port"] then
    options["port"] = 6379
  end

  return setmetatable({ options = options, enable_redis_sorted_list_renewal= auto_ssl_instance:get("enable_redis_sorted_list_renewal") }, { __index = _M })
end

-- Opens a connection for a single operation, pulling one out of the
-- keepalive pool below when available. Call sites should go through
-- with_connection() (see below) rather than calling this directly, so the
-- connection is always deterministically released or closed regardless of
-- the outcome (easy to miss across early-return error paths otherwise).
function _M.get_connection(self)
  local connection = redis:new()
  local ok, err

  local connect_options = self.options["connect_options"] or {}
  local timeouts = self.options["timeouts"] or { conn = 3000, send = 3000, read = 3000 }
  if connection.set_timeouts then
    connection:set_timeouts(timeouts["conn"], timeouts["send"], timeouts["read"])
  else
    -- set_timeouts() (plural, separate connect/send/read timeouts) was only
    -- added to lua-resty-redis in v0.28 (2020); the openresty1.13/lua51 test
    -- images bundle 0.25/0.26, which only have the older, single-value
    -- set_timeout(ms). Fall back to the largest of the three configured
    -- values there, so no operation times out earlier than intended.
    connection:set_timeout(math.max(timeouts["conn"], timeouts["send"], timeouts["read"]))
  end

  if self.options["socket"] then
    ok, err = connection:connect(self.options["socket"], connect_options)
  else
    ok, err = connection:connect(self.options["host"], self.options["port"], connect_options)
  end
  if not ok then
    return false, err
  end

  -- A connection pulled back out of the keepalive pool below already has
  -- AUTH/SELECT applied from its previous use -- skip redoing that
  -- handshake on every single operation, so pooling actually saves the round
  -- trips it's meant to, not just the initial TCP connect.
  local reused_times = connection:get_reused_times()
  if not reused_times or reused_times == 0 then
    if self.options["auth"] then
      ok, err = connection:auth(self.options["auth"])
      if not ok then
        return false, err
      end
    end

    if self.options["db"] then
      ok, err = connection:select(self.options["db"])
      if not ok then
        return false, err
      end
    end
  end

  return connection
end

-- Runs fn(connection) once against a pooled connection and returns its
-- result/err.
--
-- A connection pulled back out of the keepalive pool can have already been
-- closed by the other end (Redis idle timeout, a NAT/firewall idle-kill)
-- with no way to detect that ahead of time over a cosocket -- the only way
-- to find out is to actually try a command on it, which is exactly what fn
-- does. So if fn fails specifically on a reused connection, silently retry
-- once on a fresh connection instead of treating this expected race as a
-- real failure -- every operation this wraps (an absolute SET, an absolute
-- EXPIRE, a read) is naturally idempotent, so re-running one is safe.
--
-- A connection whose command failed is always closed rather than released
-- back to the pool -- releasing (set_keepalive) an already-broken connection
-- just fails too, adding a second, noisier log line on top of the original
-- failure for no benefit.
local function with_connection(self, fn)
  local connection, connection_err = self:get_connection()
  if connection_err then
    return nil, connection_err
  end

  local reused_times = connection:get_reused_times()
  local result, err = fn(connection)

  if not err then
    self:release_connection(connection)
    return result, err
  end

  connection:close()

  if not reused_times or reused_times == 0 then
    -- Already a fresh connection -- retrying won't change anything.
    return result, err
  end

  local retry_connection, retry_connection_err = self:get_connection()
  if retry_connection_err then
    return nil, retry_connection_err
  end

  result, err = fn(retry_connection)
  if err then
    retry_connection:close()
  else
    self:release_connection(retry_connection)
  end

  return result, err
end

-- Returns the connection to the built-in connection pool, so future
-- get_connection() calls (including from other requests) can reuse the
-- underlying TCP connection instead of paying for a new handshake each time.
function _M.release_connection(self, connection)
  local keepalive = self.options["keepalive"] or {}
  local ok, err = connection:set_keepalive(keepalive["keepalive_duration"] or 300000, keepalive["pool_size"] or 10) -- 10 conn for 5 mins, by default
  if not ok then
    ngx.log(ngx.ERR, "[auto-ssl][redis_storage]: failed to set keepalive on redis connection: ", err)
  end
end

function _M.setup()
end

function _M.get(self, key)
  return with_connection(self, function(connection)
    local res, err = connection:get(prefixed_key(self, key))
    if res == ngx.null then
      res = nil
    end
    return res, err
  end)
end

function _M.set(self, key, value, options)
  return with_connection(self, function(connection)
    local prefixed = prefixed_key(self, key)
    local ok, err = connection:set(prefixed, value)
    if ok and options and options["exptime"] then
      local _, expire_err = connection:expire(prefixed, options["exptime"])
      if expire_err then
        ngx.log(ngx.ERR, "[auto-ssl][redis_storage]: failed to set expire: ", expire_err)
      end
      if self.enable_redis_sorted_list_renewal then
        local _, zadd_err = connection:zadd(_M.certs_zlist, ngx.time() + options["exptime"], prefixed) -- add to sorted list with expiry time as score
        if zadd_err then
          ngx.log(ngx.ERR, "[auto-ssl][redis_storage]: failed to add `", prefixed, "` to sorted list: ", zadd_err)
        end
      end
    end
    return ok, err
  end)
end

function _M.delete(self, key)
  return with_connection(self, function(connection)
    local prefixed = prefixed_key(self, key)
    if self.enable_redis_sorted_list_renewal then
      local _, zrem_err = connection:zrem(_M.certs_zlist, prefixed) -- remove expired keys from the sorted list
      if zrem_err then
        ngx.log(ngx.ERR, "[auto-ssl][redis_storage]: failed to remove `", prefixed, "` from sorted list: ", zrem_err)
      end
    end
    return connection:expire(prefixed, 0)
  end)
end

function _M.keys_with_suffix(self, suffix)
  local keys, err = with_connection(self, function(connection)
    return connection:keys(prefixed_key(self, "*" .. suffix))
  end)

  if keys and self.options["prefix"] then
    local unprefixed_keys = {}
    -- First character past the prefix and a colon
    local offset = string.len(self.options["prefix"]) + 2

    for _, key in ipairs(keys) do
      local unprefixed = string.sub(key, offset)
      table.insert(unprefixed_keys, unprefixed)
    end

    keys = unprefixed_keys
  end

  return keys, err
end

-- custom function using sorted list to get certs for renewal based on expiry threshold (score)
function _M.keys_with_suffix_under_expiry_threashold(self, expiry_threshold)
  local keys, err = with_connection(self, function(connection)
    return connection:zrangebyscore( _M.certs_zlist, 0, expiry_threshold )
  end)

  if keys and self.options["prefix"] then
    local unprefixed_keys = {}
    -- First character past the prefix and a colon
    local offset = string.len(self.options["prefix"]) + 2

    for _, key in ipairs(keys) do
      local unprefixed = string.sub(key, offset)
      table.insert(unprefixed_keys, unprefixed)
    end

    keys = unprefixed_keys
  end

  return keys, err
end


return _M
