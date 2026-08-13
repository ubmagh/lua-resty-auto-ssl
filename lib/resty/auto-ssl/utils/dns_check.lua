local resolver = require "resty.dns.resolver"

-- Checks whether a domain's DNS actually resolves before an ACME attempt is
-- made for it, so a domain that doesn't point here yet (DNS not configured,
-- not propagated, a typo, etc.) doesn't burn a real issuance/renewal attempt
-- -- and the ACME-order quota that comes with one (see issue_max_concurrency/
-- max_acme_orders) -- on a request that would just fail HTTP-01 validation
-- anyway.
--
-- Two layers, both configurable:
--   1. Baseline (always applied when enabled): the domain must resolve to at
--      least one A record at all. Catches the common case outright.
--   2. Optional, stricter: if dns_check_allowed_targets is set, at least one
--      resolved address (or CNAME target) must match an entry in it -- e.g.
--      this server's own public IP(s). Off unless explicitly configured,
--      since guessing a server's own address reliably isn't something this
--      library can safely do on its own (multiple interfaces, NAT, load
--      balancers, etc.).
return function(auto_ssl_instance, domain)
  if not auto_ssl_instance:get("enable_dns_check_before_issuance") then
    return true
  end

  local r, new_err = resolver:new({
    nameservers = auto_ssl_instance:get("dns_check_nameservers"),
    retrans = 3,
    timeout = 2000, -- 2s
  })
  if not r then
    ngx.log(ngx.ERR, "[auto-ssl][dns_check]: failed to create DNS resolver for ", domain, ": ", new_err)
    return false
  end

  local answers, query_err = r:query(domain, { qtype = r.TYPE_A }, {})
  if not answers or answers.errcode then
    ngx.log(ngx.ERR, "[auto-ssl][dns_check]: ", domain, " does not resolve, skipping ACME attempt: ", query_err or (answers and answers.errstr) or "no answer")
    return false
  end

  local allowed_targets = auto_ssl_instance:get("dns_check_allowed_targets")
  if allowed_targets and #allowed_targets > 0 then
    for _, ans in ipairs(answers) do
      for _, target in ipairs(allowed_targets) do
        if ans.address == target or ans.cname == target then
          return true
        end
      end
    end

    ngx.log(ngx.ERR, "[auto-ssl][dns_check]: ", domain, " does not resolve to any configured dns_check_allowed_targets, skipping ACME attempt")
    return false
  end

  return true
end
