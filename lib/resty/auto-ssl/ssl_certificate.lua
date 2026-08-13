local concurrency = require "resty.auto-ssl.utils.concurrency"
local dns_check = require "resty.auto-ssl.utils.dns_check"
local lock = require "resty.lock"
local ssl = require "ngx.ssl"
local ssl_provider = require "resty.auto-ssl.ssl_providers.lets_encrypt"

-- TTL on issuance concurrency slots so they auto-release if a worker dies
-- mid-issuance (preventing the concurrency budget from leaking).
local ISSUE_SLOT_TTL = 120

local function convert_to_der_and_cache(domain, cert)
  -- Convert certificate from PEM to DER format.
  local fullchain_der, fullchain_der_err = ssl.cert_pem_to_der(cert["fullchain_pem"])
  if not fullchain_der or fullchain_der_err then
    return nil, "failed to convert certificate chain from PEM to DER: " .. (fullchain_der_err or "")
  end

  -- Convert private key from PEM to DER format.
  local privkey_der, privkey_der_err = ssl.priv_key_pem_to_der(cert["privkey_pem"])
  if not privkey_der or privkey_der_err then
    return nil, "failed to convert private key from PEM to DER: " .. (privkey_der_err or "")
  end

  -- Cache DER formats in memory for 1 hour (so renewals will get picked up
  -- across multiple servers).
  local _, set_fullchain_err, set_fullchain_forcible = ngx.shared.auto_ssl:set("domain:fullchain_der:" .. domain, fullchain_der, 3600)
  if set_fullchain_err then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: failed to set shdict cache of certificate chain for " .. domain .. ": ", set_fullchain_err)
  elseif set_fullchain_forcible then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: 'lua_shared_dict auto_ssl' might be too small - consider increasing its configured size (old entries were removed while adding certificate chain for " .. domain .. ")")
  end

  local _, set_privkey_err, set_privkey_forcible = ngx.shared.auto_ssl:set("domain:privkey_der:" .. domain, privkey_der, 3600)
  if set_privkey_err then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: failed to set shdict cache of private key for " .. domain .. ": ", set_privkey_err)
  elseif set_privkey_forcible then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: 'lua_shared_dict auto_ssl' might be too small - consider increasing its configured size (old entries were removed while adding private key for " .. domain .. ")")
  end

  return {
    fullchain_der = fullchain_der,
    privkey_der = privkey_der,
  }
end

local function issue_cert_unlock(domain, storage, local_lock, distributed_lock_value)
  if local_lock then
    local _, local_unlock_err = local_lock:unlock()
    if local_unlock_err then
      ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: failed to unlock: ", local_unlock_err)
    end
  end

  if distributed_lock_value then
    local _, distributed_unlock_err = storage:issue_cert_unlock(domain, distributed_lock_value)
    if distributed_unlock_err then
      ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: failed to unlock: ", distributed_unlock_err)
    end
  end
end

local function issue_cert(auto_ssl_instance, storage, domain)
  -- Before issuing a cert, create a local lock to ensure multiple workers
  -- don't simultaneously try to register the same cert.
  -- exptime must outlive a full issuance (dehydrated can run up to ~60s, see
  -- shell_execute's timeout) so the lock isn't auto-released mid-issuance,
  -- which would let a second concurrent order start for the same domain and
  -- race its authorizations against the first.
  local local_lock, new_local_lock_err = lock:new("auto_ssl", { exptime = 120, timeout = 30 })
  if new_local_lock_err then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: failed to create lock: ", new_local_lock_err)
    return
  end
  local _, local_lock_err = local_lock:lock("issue_cert:" .. domain)
  if local_lock_err then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: failed to obtain lock: ", local_lock_err)
    return
  end

  -- Also add a lock to the configured storage adapter, which allows for a
  -- distributed lock across multiple servers (depending on the storage
  -- adapter).
  local distributed_lock_value, distributed_lock_err = storage:issue_cert_lock(domain)
  if distributed_lock_err then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: failed to obtain lock: ", distributed_lock_err)
    issue_cert_unlock(domain, storage, local_lock, nil)
    return
  end

  -- After obtaining the local and distributed lock, see if the certificate
  -- has already been registered.
  local cert, err = storage:get_cert(domain)
  if err then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: error fetching certificate from storage for ", domain, ": ", err)
  end

  if cert and cert["fullchain_pem"] and cert["privkey_pem"] then
    issue_cert_unlock(domain, storage, local_lock, distributed_lock_value)
    return cert
  end

  ngx.log(ngx.NOTICE, "[auto-ssl][ssl_certificate]: issuing new certificate for ", domain)
  cert, err = ssl_provider.issue_cert(auto_ssl_instance, domain)
  if err and err ~= "acme rate limit reached" then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: issuing new certificate failed: ", err)
  end

  issue_cert_unlock(domain, storage, local_lock, distributed_lock_value)
  return cert, err
end

-- When a certificate served from storage is within the renewal window (or
-- already expired, or missing an expiry date), kick off a non-blocking
-- background renewal for just that domain (see jobs/renewal.lua's
-- renew_domain). The current request is still served the existing
-- certificate with zero added latency; once the renewal completes it clears
-- the in-memory DER cache so the next request picks up the freshly-issued
-- cert, instead of continuing to serve the stale cached copy for up to its
-- cache lifetime (1 hour).
--
-- A per-domain dedup lock in the shared dict ensures this only actually
-- triggers a renewal once per renew_trigger_dedup_time, rather than
-- spawning a timer (and an ACME attempt) on every single request to an
-- expiring/expired domain. Opt-in via enable_on_demand_renewal, since this
-- runs on every cache-miss request and complements (rather than replaces)
-- the periodic sweep.
local function maybe_trigger_renewal(auto_ssl_instance, domain, cert)
  if not auto_ssl_instance:get("enable_on_demand_renewal") then
    return
  end

  local expiry = cert["expiry"]
  local renew_age_days = auto_ssl_instance:get("renew_age_days")
  if expiry and (expiry - ngx.now()) >= (renew_age_days * 24 * 60 * 60) then
    return
  end

  local ok = ngx.shared.auto_ssl:add("domain:renew_hit_lock:" .. domain, true, auto_ssl_instance:get("renew_trigger_dedup_time"))
  if not ok then
    return
  end

  ngx.log(ngx.NOTICE, "[auto-ssl][ssl_certificate]: triggering on-demand renewal for ", domain)
  local renewal = require "resty.auto-ssl.jobs.renewal"
  renewal.renew_domain(auto_ssl_instance, domain)
end

local function get_cert_der(auto_ssl_instance, domain, ssl_options)
  -- Look for the certificate in shared memory first.
  local fullchain_der = ngx.shared.auto_ssl:get("domain:fullchain_der:" .. domain)
  local privkey_der = ngx.shared.auto_ssl:get("domain:privkey_der:" .. domain)
  if fullchain_der and privkey_der then
    return {
      fullchain_der = fullchain_der,
      privkey_der = privkey_der,
      newly_issued = false,
    }
  end

  -- Check to ensure the domain is one we allow for handling SSL.
  --
  -- Note: We perform this after the memory lookup, so more costly
  -- "allow_domain" lookups can be avoided for cached certs. However, we will
  -- perform this before the storage lookup, since the storage lookup could
  -- also be more costly (or blocking in the case of the file storage adapter).
  -- We may want to consider caching the results of allow_domain lookups
  -- (including negative caching or disallowed domains).
  local allow_domain = auto_ssl_instance:get("allow_domain")
  if not allow_domain(domain, auto_ssl_instance, ssl_options, false) then
    return nil, "domain not allowed"
  end

  -- Next, look for the certificate in permanent storage (which can be shared
  -- across servers depending on the storage).
  local storage = auto_ssl_instance.storage
  local cert, get_cert_err = storage:get_cert(domain)
  if get_cert_err then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: error fetching certificate from storage for ", domain, ": ", get_cert_err)
  end

  if cert and cert["fullchain_pem"] and cert["privkey_pem"] then
    -- Serve the existing cert, but if it's within the renewal window kick
    -- off a non-blocking background renewal so expiring/expired certs
    -- self-heal on access, without waiting for the periodic sweep.
    maybe_trigger_renewal(auto_ssl_instance, domain, cert)

    local cert_der, cert_der_err = convert_to_der_and_cache(domain, cert)

    if cert_der_err then
      ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: error converting certificate for ", domain, ": ", cert_der_err)
    end

    if not cert_der then
      return nil, "empty cert_der received"
    end

    cert_der["newly_issued"] = false
    return cert_der
  end

  -- Finally, issue a new certificate if one hasn't been found yet.
  if not ssl_options or ssl_options["generate_certs"] ~= false then
    -- Skip the ACME attempt entirely if the domain's DNS doesn't actually
    -- resolve (here, or to an allowed target -- see dns_check.lua) --
    -- avoids wasting a real issuance attempt, and the quota that comes with
    -- one, on a domain that would just fail HTTP-01 validation anyway.
    if not dns_check(auto_ssl_instance, domain) then
      return nil, "dns check failed"
    end

    -- Optionally cap the number of concurrent new-certificate issuances
    -- (each shells out to dehydrated via sockproc). When issue_max_concurrency
    -- is set and all slots are busy, skip issuing on this request and serve
    -- the fallback instead; the domain will be retried on a subsequent
    -- request. This replaces the need for a custom rate-limit in
    -- allow_domain.
    local max_issue = auto_ssl_instance:get("issue_max_concurrency")
    local issue_slot
    if max_issue then
      issue_slot = concurrency.acquire("issue_slot:", max_issue, ISSUE_SLOT_TTL)
      if not issue_slot then
        return nil, "issuance concurrency limit reached"
      end
    end

    local issue_err
    cert, issue_err = issue_cert(auto_ssl_instance, storage, domain)
    concurrency.release("issue_slot:", issue_slot)

    if issue_err == "acme rate limit reached" then
      return nil, "acme rate limit reached"
    end

    if cert and cert["fullchain_pem"] and cert["privkey_pem"] then
      local cert_der, cert_der_err = convert_to_der_and_cache(domain, cert)
      if cert_der_err then
        ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: error converting certificate for ", domain, ": ", cert_der_err)
      end

      if not cert_der then
        return nil, "empty cert_der received"
      end

      cert_der["newly_issued"] = true
      return cert_der
    end
  else
    return nil, "did not issue certificate, because the generate_certs setting is false"
  end

  -- Return an error if issuing the certificate failed.
  return nil, "failed to get or issue certificate"
end

local function set_response_cert(cert_der)
  local ok, err

  -- Clear the default fallback certificates (defined in the hard-coded nginx
  -- config).
  ok, err = ssl.clear_certs()
  if not ok then
    return nil, "failed to clear existing (fallback) certificates - " .. (err or "")
  end

  -- Set the public certificate chain.
  ok, err = ssl.set_der_cert(cert_der["fullchain_der"])
  if not ok then
    return nil, "failed to set certificate - " .. (err or "")
  end

  -- Set the private key.
  ok, err = ssl.set_der_priv_key(cert_der["privkey_der"])
  if not ok then
    return nil, "failed to set private key - " .. (err or "")
  end
end

local function do_ssl(auto_ssl_instance, ssl_options)
  -- Determine the domain making the SSL request with SNI.
  local request_domain = auto_ssl_instance:get("request_domain")
  local domain, domain_err = request_domain(ssl, ssl_options)
  if not domain or domain_err then
    ngx.log(ngx.WARN, "could not determine domain for request (SNI not supported?) - using fallback - " .. (domain_err or ""))
    return
  end

  domain = string.lower(domain)

  -- Get or issue the certificate for this domain.
  local cert_der, get_cert_der_err = get_cert_der(auto_ssl_instance, domain, ssl_options)
  if get_cert_der_err then
    if get_cert_der_err == "domain not allowed" then
      ngx.log(ngx.NOTICE, "[auto-ssl][ssl_certificate]: domain not allowed - using fallback - ", domain)
    elseif get_cert_der_err == "issuance concurrency limit reached" then
      ngx.log(ngx.NOTICE, "[auto-ssl][ssl_certificate]: issuance concurrency limit reached - using fallback - ", domain)
    elseif get_cert_der_err == "acme rate limit reached" then
      ngx.log(ngx.NOTICE, "[auto-ssl][ssl_certificate]: ACME rate limit reached - using fallback - ", domain)
    elseif get_cert_der_err == "dns check failed" then
      ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: DNS check failed, not issuing - using fallback - ", domain)
    else
      ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: could not get certificate for ", domain, " - using fallback - ", get_cert_der_err)
    end
    return
  elseif not cert_der or not cert_der["fullchain_der"] or not cert_der["privkey_der"] then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: certificate data unexpectedly missing for ", domain, " - using fallback")
    return
  end

  -- Set the certificate on the response.
  local _, set_response_cert_err = set_response_cert(cert_der)
  if set_response_cert_err then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: failed to set certificate for ", domain, " - using fallback - ", set_response_cert_err)
    return
  end
end

return function(auto_ssl_instance, ssl_options)
  local ok, err = pcall(do_ssl, auto_ssl_instance, ssl_options)
  if not ok then
    ngx.log(ngx.ERR, "[auto-ssl][ssl_certificate]: failed to run do_ssl: ", err)
  end
end
