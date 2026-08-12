local concurrency = require "resty.auto-ssl.utils.concurrency"
local lock = require "resty.lock"
local parse_openssl_time = require "resty.auto-ssl.utils.parse_openssl_time"
local shell_execute = require "resty.auto-ssl.utils.shell_execute"
local shuffle_table = require "resty.auto-ssl.utils.shuffle_table"
local ssl_provider = require "resty.auto-ssl.ssl_providers.lets_encrypt"

local _M = {}

-- Based on lua-rest-upstream-healthcheck's lock:
-- https://github.com/openresty/lua-resty-upstream-healthcheck/blob/v0.03/lib/resty/upstream/healthcheck.lua#L423-L440
--
-- This differs from resty-lock by ensuring that the task only gets executed
-- once per interval across all workers. resty-lock helps ensure multiple
-- concurrent tasks don't run (in case the task takes longer than interval).
local function get_interval_lock(name, interval)
  local key = "lock:" .. name

  -- the lock is held for the whole interval to prevent multiple
  -- worker processes from sending the test request simultaneously.
  -- here we substract the lock expiration time by 1ms to prevent
  -- a race condition with the next timer event.
  local ok, err = ngx.shared.auto_ssl:add(key, true, interval - 0.001)
  if not ok then
    if err == "exists" then
      return nil
    end
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to add key \"", key, "\": ", err)
    return nil
  end
  return true
end

local function renew_check_cert_unlock(domain, storage, local_lock, distributed_lock_value)
  if local_lock then
    local _, local_unlock_err = local_lock:unlock()
    if local_unlock_err then
      ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to unlock: ", local_unlock_err)
    end
  end

  if distributed_lock_value then
    local _, distributed_unlock_err = storage:issue_cert_unlock(domain, distributed_lock_value)
    if distributed_unlock_err then
      ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to unlock: ", distributed_unlock_err)
    end
  end
end

local function delete_cert_if_expired(domain, storage, cert)
  -- Give up on renewing this certificate if we didn't manage to renew
  -- it before the expiration date
  if cert["expiry"] and cert["expiry"] < ngx.now() then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: existing certificate is expired, deleting: ", domain)
    storage:delete_cert(domain)
  end
end

local function renew_check_cert(auto_ssl_instance, storage, domain)
  -- Before issuing a cert, create a local lock to ensure multiple workers
  -- don't simultaneously try to register the same cert.
  -- exptime must outlive a full issuance (dehydrated can run up to ~60s, see
  -- shell_execute's timeout) so the lock isn't auto-released mid-issuance,
  -- which would let a second concurrent order start for the same domain and
  -- race its authorizations against the first.
  local local_lock, new_local_lock_err = lock:new("auto_ssl", { exptime = 120, timeout = 30 })
  if new_local_lock_err then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to create lock: ", new_local_lock_err)
    return
  end
  local _, local_lock_err = local_lock:lock("issue_cert:" .. domain)
  if local_lock_err then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to obtain lock: ", local_lock_err)
    return
  end

  -- Also add a lock to the configured storage adapter, which allows for a
  -- distributed lock across multiple servers (depending on the storage
  -- adapter).
  local distributed_lock_value, distributed_lock_err = storage:issue_cert_lock(domain)
  if distributed_lock_err then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to obtain lock: ", distributed_lock_err)
    renew_check_cert_unlock(domain, storage, local_lock, nil)
    return
  end

  ngx.log(ngx.NOTICE, "[auto-ssl][renewal]: checking certificate renewals for ", domain)

  -- Fetch the current certificate.
  local cert, get_cert_err = storage:get_cert(domain)
  if get_cert_err then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: renewal error fetching certificate from storage for ", domain, ": ", get_cert_err)
  end
  if not cert then
    cert = {}
  end

  if not cert["fullchain_pem"] then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: attempting to renew certificate for domain without certificates in storage: ", domain) -- this requires a new cert to be issued.
    renew_check_cert_unlock(domain, storage, local_lock, distributed_lock_value)
    return
  end

  -- While newer certs should have the expire date stored already, if an older
  -- cert doesn't have an expiry date stored yet, extract it and save it.
  if not cert["expiry"] then
    local cert_pem_path = auto_ssl_instance:get("dir") .. "/tmp/extract-expiry-" .. ngx.escape_uri(domain)
    local file, file_err = io.open(cert_pem_path, "w")
    if file_err then
      ngx.log(ngx.ERR, "[auto-ssl][renewal]: write expiry cert file for " .. domain .. " failed: ", file_err)
    else
      file:write(cert["fullchain_pem"])
      file:close()

      local date_result, date_err = shell_execute({ "openssl", "x509", "-enddate", "-noout", "-in", cert_pem_path })
      if date_err or date_result["status"] ~= 0 then
        ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to extract expiry date from cert: ", date_err)
      else
        local expiry, parse_err = parse_openssl_time(date_result["output"])
        if parse_err then
          ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to parse expiry date: ", parse_err)
        else
          cert["expiry"] = expiry

          -- Update stored certificate to include expiry information
          ngx.log(ngx.NOTICE, "[auto-ssl][renewal]: setting expiration date of ",  domain, " to ", cert["expiry"])
          local _, set_cert_err = storage:set_cert(domain, cert["fullchain_pem"], cert["privkey_pem"], cert["cert_pem"], cert["expiry"])
          if set_cert_err then
            ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to update cert: ", set_cert_err)
          end
        end
      end

      local _, remove_err = os.remove(cert_pem_path)
      if remove_err then
        ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to remove expiry cert file: ", remove_err)
      end
    end
  end

  -- If expiry date is known, attempt renewal if it's within 30 days.
  if cert["expiry"] then
    local renew_age_days = auto_ssl_instance:get("renew_age_days")
    local now = ngx.now()
    if now + (renew_age_days * 24 * 60 * 60) < cert["expiry"] then
      ngx.log(ngx.NOTICE, "[auto-ssl][renewal]: expiry date is more than configured `renew_age_days` days out, skipping renewal: ", domain)
      renew_check_cert_unlock(domain, storage, local_lock, distributed_lock_value)
      return
    end
  end

  -- Check if domain is still allowed before renewing.
  local allow_domain = auto_ssl_instance:get("allow_domain")
  if not allow_domain(domain, auto_ssl_instance, nil, true) then
    ngx.log(ngx.NOTICE, "[auto-ssl][renewal]: domain not allowed, not renewing: ", domain)
    delete_cert_if_expired(domain, storage, cert)
    renew_check_cert_unlock(domain, storage, local_lock, distributed_lock_value)
    return
  end

  -- We didn't previously store the cert.pem (since it can be derived from the
  -- fullchain.pem). So for backwards compatibility, set the cert.pem value to
  -- the fullchain.pem value, since that should work for our date checking
  -- purposes.
  if not cert["cert_pem"] then
    cert["cert_pem"] = cert["fullchain_pem"]
  end

  -- Write out the cert.pem value to the location dehydrated expects it for
  -- checking.
  ngx.log(ngx.ERR, "[auto-ssl][renewal-debug]: running into the renewal of :  "..domain.." expiry_field: "..ngx.http_time(cert["expiry"]))
  local dir = auto_ssl_instance:get("dir") .. "/letsencrypt/certs/" .. domain
  local mkdir_result, mkdir_err = shell_execute({ "mkdir", "-p", dir })
  if mkdir_err or mkdir_result["status"] ~= 0 then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to create letsencrypt/certs dir: ", mkdir_err)
    renew_check_cert_unlock(domain, storage, local_lock, distributed_lock_value)
    return false, mkdir_err
  end
  local cert_pem_path = dir .. "/cert.pem"
  local file, err = io.open(cert_pem_path, "w")
  if err then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: write cert.pem for " .. domain .. " failed: ", err)
    renew_check_cert_unlock(domain, storage, local_lock, distributed_lock_value)
    return false, err
  end
  file:write(cert["cert_pem"])
  file:close()

  -- Trigger a normal certificate issuance attempt, which dehydrated will
  -- skip if the certificate already exists or renew if it's within the
  -- configured time for renewals.
  local renewed_cert, issue_err = ssl_provider.issue_cert(auto_ssl_instance, domain)
  if issue_err then
    if issue_err == "acme rate limit reached" then
      -- Defer rather than fail: leave the existing cert in place (do NOT
      -- delete even if expired) so it's retried on a later request/sweep
      -- once the rate limit window clears.
      ngx.log(ngx.NOTICE, "[auto-ssl][renewal]: renewal deferred, ACME rate limit reached: ", domain)
    else
      -- Keep the existing cert (even if expired) and retry on a later
      -- request/sweep rather than deleting it. A failed renewal usually
      -- can't be recovered by dropping to on-demand issuance (same ACME
      -- path), so deleting would only swap an expired-but-real cert for the
      -- fallback and discard the stored cert/key. Transient failures (e.g.
      -- a finalize race) simply succeed on the next attempt. Deletion still
      -- happens above when allow_domain rejects the domain outright.
      ngx.log(ngx.ERR, "[auto-ssl][renewal]: issuing renewal certificate failed: ", issue_err)
    end
  else
    -- Log success at NOTICE so completed renewals are visible (issue_cert
    -- itself only logs at DEBUG on success).
    local new_expiry = renewed_cert and renewed_cert["expiry"]
    ngx.log(ngx.NOTICE, "[auto-ssl][renewal]: renewed certificate for ", domain, new_expiry and (" (expiry: " .. new_expiry .. ")") or "")

    -- Invalidate the in-memory DER cache so the freshly-issued certificate
    -- is picked up on the next request, rather than continuing to serve the
    -- stale cached cert for up to its cache lifetime (1 hour). No OCSP
    -- shdict key to clear here -- OCSP stapling support was removed
    -- entirely from this fork (see "Remove OCSP stapling support" in
    -- FORKCHANGES.md).
    ngx.shared.auto_ssl:delete("domain:fullchain_der:" .. domain)
    ngx.shared.auto_ssl:delete("domain:privkey_der:" .. domain)
  end

  renew_check_cert_unlock(domain, storage, local_lock, distributed_lock_value)
end

local function renew_all_domains(auto_ssl_instance)
  -- Loop through all known domains and check to see if they should be renewed.
  local storage = auto_ssl_instance.storage
  local expiry_threshold = (auto_ssl_instance:get("renew_age_days") * 24 * 60 * 60) + ngx.time() + 60
  local domains, domains_err = storage:get_certs_for_renewal( expiry_threshold, auto_ssl_instance:get("enable_redis_sorted_list_renewal") )
  if domains_err then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to fetch all certificate domains, error: ", domains_err)
  else
    -- Randomize the renewal order so that if nginx is reloaded during renewals
    -- or rate limits are hit, the renewals are attempted in a different order
    -- each time (which may allow things to eventually succeed over multiple
    -- renewal attempts).
    shuffle_table(domains)
    ngx.log(ngx.ERR, "[auto-ssl][renewal-debug]: started renewing all domains at: "..tostring(ngx.time())  )
    local domains_counter = 0
    for _, domain in ipairs(domains) do
      domains_counter = domains_counter + 1
      ngx.log(ngx.ERR, "[auto-ssl][renewal-debug]: Domain-counter is at -> "..tostring(domains_counter)  )
      renew_check_cert(auto_ssl_instance, storage, string.lower(domain))
    end
    ngx.log(ngx.ERR, "[auto-ssl][renewal-debug]: ended renewing all domains at: "..tostring(ngx.time()) )
  end
end

local function do_renew(auto_ssl_instance)
  -- Ensure only 1 worker executes the renewal once per interval.
  if not get_interval_lock("renew", auto_ssl_instance:get("renew_check_interval")) then
    ngx.log(ngx.ERR, "[auto-ssl][renewal-debug]: can't launch renew, renewal-state is locked for another worker for the renew_check_interval duration")
    return
  end
  local renew_lock, new_renew_lock_err = lock:new("auto_ssl_settings", { exptime = 1800, timeout = 0 })
  if new_renew_lock_err then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to create lock: ", new_renew_lock_err)
    return
  end
  local _, lock_err = renew_lock:lock("renew")
  if lock_err then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to obtain lock: ", lock_err)
    return
  end

  local renew_ok, renew_err = pcall(renew_all_domains, auto_ssl_instance)
  if not renew_ok then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to run do_renew cycle: ", renew_err)
  end

  local ok, unlock_err = renew_lock:unlock()
  if not ok then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to unlock: ", unlock_err)
  end
end

-- Call the renew function in an infinite loop (by default once per day).
local function renew(premature, auto_ssl_instance)
  if premature then return end

  local enable_internal_renew_schedule = auto_ssl_instance:get("enable_internal_renew_schedule")
  if not enable_internal_renew_schedule then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: stopping the internal renewal recursive schedule; set enable_internal_renew_schedule to true to enable it")
    return
  end

  local renew_ok, renew_err = pcall(do_renew, auto_ssl_instance)
  if not renew_ok then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to run do_renew cycle: ", renew_err)
  end

  local timer_ok, timer_err = ngx.timer.at(auto_ssl_instance:get("renew_check_interval"), renew, auto_ssl_instance)
  if not timer_ok then
    if timer_err ~= "process exiting" then
      ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to create timer: ", timer_err)
    end
    return
  end
end

function _M.spawn(auto_ssl_instance)
  local ok, err = ngx.timer.at(auto_ssl_instance:get("renew_check_interval"), renew, auto_ssl_instance)
  if not ok then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to create timer: ", err)
    return
  end
end

-- On-demand renewals (see ssl_certificate.lua's maybe_trigger_renewal) can
-- optionally be capped to `renew_max_concurrency` running at once (unset by
-- default -- uncapped, opt-in). Each renewal shells out via sockproc, so an
-- unbounded burst (many domains being hit at the same time) can exceed
-- sockproc's accept backlog and get "connection reset by peer" -- worth
-- capping if that becomes a problem in practice; also naturally throttles
-- the ACME request rate against Let's Encrypt's limits. When capped, slots
-- are held in the shared dict with a TTL so they auto-release even if a
-- worker dies mid-renewal (preventing the concurrency budget from leaking).
local RENEW_SLOT_TTL = 300

-- Timer callback to renew a single domain immediately, using the same
-- locking and renewal logic as the periodic sweep. Intended to be triggered
-- from a non-blocking timer when a request is served a certificate that is
-- within the renewal window (see ssl_certificate.lua).
local function renew_single_domain(premature, auto_ssl_instance, domain, slot)
  if premature then
    concurrency.release("renew_slot:", slot)
    return
  end

  local renew_ok, renew_err = pcall(renew_check_cert, auto_ssl_instance, auto_ssl_instance.storage, domain)
  if not renew_ok then
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to run on-demand renewal for ", domain, ": ", renew_err)
  end

  concurrency.release("renew_slot:", slot)
end

-- Kick off a non-blocking background renewal for a single domain. Returns
-- immediately so the current request is unaffected. If renew_max_concurrency
-- is configured and already reached, skips (returning false) instead --
-- the domain will be retried on a later request.
function _M.renew_domain(auto_ssl_instance, domain)
  -- Only attempt to acquire a slot if renew_max_concurrency is actually
  -- configured -- unset means uncapped, not "no slots available". Mirrors
  -- how issue_max_concurrency gates issuance's own slot in ssl_certificate.lua.
  local max_renew = auto_ssl_instance:get("renew_max_concurrency")
  local slot
  if max_renew then
    slot = concurrency.acquire("renew_slot:", max_renew, RENEW_SLOT_TTL)
    if not slot then
      return false, "renewal concurrency limit reached"
    end
  end

  local ok, err = ngx.timer.at(0, renew_single_domain, auto_ssl_instance, domain, slot)
  if not ok then
    concurrency.release("renew_slot:", slot)
    ngx.log(ngx.ERR, "[auto-ssl][renewal]: failed to create on-demand renewal timer for ", domain, ": ", err)
    return false, err
  end

  return true
end

-- exposed function to be called from the api vhost, for manual triggered renewals
_M.do_renew = do_renew

return _M
