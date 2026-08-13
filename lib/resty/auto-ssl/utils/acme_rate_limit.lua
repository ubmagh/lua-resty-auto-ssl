local _M = {}

-- Account-wide fixed-window rate limiter for Let's Encrypt orders.
--
-- Both new issuance and renewal create ACME orders against the same Let's
-- Encrypt account and therefore share the same rate limits (notably 300 new
-- orders per 3 hours). This must be enforced globally across both paths, so
-- a single shared counter in the `auto_ssl` shared dict is used.
--
-- Returns true if an order is allowed within the current window (and counts
-- it), false if the limit has been reached. With max unset, there is no
-- limit at all.
function _M.allow(max, period)
  if not max or max < 1 then
    return true
  end

  -- incr with init=0 and init_ttl=period creates the counter on the first
  -- order of a window with a TTL of `period`, so the window resets `period`
  -- seconds after that first order. Subsequent orders within the window just
  -- increment the same counter.
  local dict = ngx.shared.auto_ssl
  local count, err = dict:incr("acme_order_count", 1, 0, period)
  if not count then
    ngx.log(ngx.ERR, "[auto-ssl][acme_rate_limit]: failed to track ACME order rate: ", err)
    -- Fail open rather than block all issuance/renewal on a tracking error.
    return true
  end

  return count <= max
end

return _M
