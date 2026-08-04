local redis = require "resty.redis"

local _M = {}

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

  return setmetatable({ options = options }, { __index = _M })
end

-- Opens a new connection for a single operation. Callers must release it
-- via release_connection() once they're done (see get/set/delete/
-- keys_with_suffix below) -- connections are not reused across multiple
-- calls, so that release is always deterministic and doesn't depend on every
-- call site remembering to clean up (which is easy to miss, e.g. across
-- early-return error paths).
function _M.get_connection(self)
  local connection = redis:new()
  local ok, err

  local connect_options = self.options["connect_options"] or {}
  if self.options["timeouts"] then
    local timeouts = self.options["timeouts"]
    connection:set_timeouts(timeouts["conn"], timeouts["send"], timeouts["read"])
  else
    connection:set_timeouts(3000, 3000, 3000)
  end

  if self.options["socket"] then
    ok, err = connection:connect(self.options["socket"], connect_options)
  else
    ok, err = connection:connect(self.options["host"], self.options["port"], connect_options)
  end
  if not ok then
    return false, err
  end

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

  return connection
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
  local connection, connection_err = self:get_connection()
  if connection_err then
    return nil, connection_err
  end

  local res, err = connection:get(prefixed_key(self, key))
  if res == ngx.null then
    res = nil
  end

  self:release_connection(connection)
  return res, err
end

function _M.set(self, key, value, options)
  local connection, connection_err = self:get_connection()
  if connection_err then
    return false, connection_err
  end

  key = prefixed_key(self, key)
  local ok, err = connection:set(key, value)
  if ok then
    if options and options["exptime"] then
      local _, expire_err = connection:expire(key, options["exptime"])
      if expire_err then
        ngx.log(ngx.ERR, "[auto-ssl][redis_storage]: failed to set expire: ", expire_err)
      end
    end
  end

  self:release_connection(connection)
  return ok, err
end

function _M.delete(self, key)
  local connection, connection_err = self:get_connection()
  if connection_err then
    return false, connection_err
  end

  local ok, err = connection:expire(prefixed_key(self, key), 0)
  self:release_connection(connection)
  return ok, err
end

function _M.keys_with_suffix(self, suffix)
  local connection, connection_err = self:get_connection()
  if connection_err then
    return false, connection_err
  end

  local keys, err = connection:keys(prefixed_key(self, "*" .. suffix))

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

  self:release_connection(connection)
  return keys, err
end

return _M
