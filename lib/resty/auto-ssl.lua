-- Ensure resty.core FFI libraries are loaded to prevent potential deadlocks in
-- shdict. These are loaded by default in OpenResty 1.15.8.1+, but this will
-- ensure this library is loaded in older versions.
--
-- https://github.com/openresty/lua-nginx-module/issues/1207#issuecomment-350742782
-- https://github.com/auto-ssl/lua-resty-auto-ssl/issues/43
-- https://github.com/auto-ssl/lua-resty-auto-ssl/issues/220
require "resty.core"

local _M = {}

local current_file_path = package.searchpath("resty.auto-ssl", package.path)
_M.lua_root = string.match(current_file_path, "(.*)/.*/.*/.*/.*/.*")
if string.sub(_M.lua_root, 1, 2) == "./" then
  local lfs = require "lfs"
  _M.lua_root = lfs.currentdir() .. string.sub(_M.lua_root, 2, -1)
end

function _M.new(options)
  if not options then
    options = {}
  end

  if not options["dir"] then
    options["dir"] = "/etc/resty-auto-ssl"
  end

  if not options["request_domain"] then
    options["request_domain"] = function(ssl, ssl_options) -- luacheck: ignore
      return ssl.server_name()
    end
  end

  if not options["allow_domain"] then
    options["allow_domain"] = function(domain, auto_ssl, ssl_options, renewal) -- luacheck: ignore
      return false
    end
  end

  if not options["storage_adapter"] then
    options["storage_adapter"] = "resty.auto-ssl.storage_adapters.file"
  end

  if not options["json_adapter"] then
    options["json_adapter"] = "resty.auto-ssl.json_adapters.cjson"
  end

  if options["enable_internal_renew_schedule"] == nil then
    options["enable_internal_renew_schedule"] = true -- if u don't have an external triggering system
  end

  if options["enable_redis_sorted_list_renewal"] == nil then
    options["enable_redis_sorted_list_renewal"] = false
  end

  if not options["renew_check_interval"] then
    options["renew_check_interval"] = 86400 -- 1 day
  end

  if not options["hook_server_port"] then
    options["hook_server_port"] = 8999
  end

  if not options["ssl_certs_keys_expire_mode"] then
    options["ssl_certs_keys_expire_mode"] = 2
  end

  if not options["challenge_keys_exptime"] then
    options["challenge_keys_exptime"] = 3600 -- 1h defaults
  end

  if not options["ssl_certs_keys_exptime"] then
    options["ssl_certs_keys_exptime"] = 7776000 -- 90 days default
  end

  if not options["renew_offset_ssl_certs_exptime"] then
    options["renew_offset_ssl_certs_exptime"] = 86400 -- 1 day
  end

  if not options["min_ssl_certs_exptime"] then
    options["min_ssl_certs_exptime"] = 86400 -- 1 day
  end

  if not options["renew_age_days"] then
    options["renew_age_days"] = 30 -- 30 days default
  end

  if not options["issue_cert_lock_wait_time"] then
    options["issue_cert_lock_wait_time"] = 90 -- max seconds to wait for an in-progress issuance lock to clear
  end

  if not options["issue_cert_lock_poll_interval"] then
    options["issue_cert_lock_poll_interval"] = 0.5 -- seconds between polls while waiting on the above
  end

  if not options["issue_cert_lock_exptime"] then
    options["issue_cert_lock_exptime"] = 120 -- how long the lock itself is held once acquired, in seconds
  end

  if options["enable_on_demand_renewal"] == nil then
    options["enable_on_demand_renewal"] = false -- opt-in: check expiry on every serve and renew due domains in the background
  end

  if not options["renew_trigger_dedup_time"] then
    options["renew_trigger_dedup_time"] = 600 -- seconds between on-demand renewal triggers for the same domain
  end

  -- Max number of on-demand renewals to run concurrently. Left unset (nil)
  -- by default, meaning unlimited -- opt in by setting a positive integer.
  -- Each on-demand renewal shells out via sockproc, so an unbounded burst
  -- under load can exceed sockproc's own accept backlog; set this if you
  -- enable enable_on_demand_renewal and want that bounded too.
  -- options["renew_max_concurrency"] = nil

  -- Max number of new-certificate issuances to run concurrently. Left unset
  -- (nil) by default, meaning unlimited (preserving prior behavior). Set to a
  -- positive integer to cap concurrent issuance instead of using a custom
  -- rate-limit in allow_domain.
  -- options["issue_max_concurrency"] = nil

  -- Account-wide cap on the number of Let's Encrypt orders (issuance AND
  -- renewal combined, since they share one ACME account/rate limit) allowed
  -- per acme_order_period. Unset by default (no limit). To stay under LE's
  -- 300 orders / 3 hours, set e.g. max_acme_orders = 250.
  -- options["max_acme_orders"] = nil

  if not options["acme_order_period"] then
    options["acme_order_period"] = 3 * 60 * 60 -- 3 hours, matching LE's window
  end

  local self =  setmetatable({ options = options }, { __index = _M })
  _M.singleton_instance = self
  return self
end

function _M.set(self, key, value)
  if key == "storage" then
    ngx.log(ngx.ERR, "[auto-ssl]: DEPRECATED: Don't use auto_ssl:set() for the 'storage' instance. Set directly with auto_ssl.storage.")
    self.storage = value
    return
  end

  self.options[key] = value
end

function _M.get(self, key)
  if key == "storage" then
    ngx.log(ngx.ERR, "[auto-ssl]: DEPRECATED: Don't use auto_ssl:get() for the 'storage' instance. Get directly with auto_ssl.storage.")
    return self.storage
  end

  return self.options[key]
end

function _M.init(self)
  local init_master = require "resty.auto-ssl.init_master"
  init_master(self)
end

function _M.init_worker(self)
  local init_worker = require "resty.auto-ssl.init_worker"
  init_worker(self)
end

function _M.ssl_certificate(self, ssl_options)
  local ssl_certificate = require "resty.auto-ssl.ssl_certificate"
  ssl_certificate(self, ssl_options)
end

function _M.challenge_server(self)
  local server = require "resty.auto-ssl.servers.challenge"
  server(self)
end

function _M.has_certificate(self, domain, shmem_only)
  local has_certificate = require "resty.auto-ssl.utils.has_certificate"
  return has_certificate(self, domain, shmem_only)
end

function _M.hook_server(self)
  local server = require "resty.auto-ssl.servers.hook"
  server(self)
end

return _M
