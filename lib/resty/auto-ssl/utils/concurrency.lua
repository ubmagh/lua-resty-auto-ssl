local _M = {}

-- Acquire one of `max` named slots backed by the `auto_ssl` shared dict, to
-- cap the number of concurrent operations (e.g. dehydrated/ACME invocations,
-- which each shell out via sockproc -- an unbounded burst can exceed
-- sockproc's own accept backlog). Returns the slot index on success, or nil
-- if all `max` slots are currently held (or `max` is unset/less than 1,
-- meaning the caller didn't opt into a cap at all).
--
-- Slots are stored with a TTL so they auto-release even if the holder dies
-- mid-operation (e.g. a worker exits), preventing the concurrency budget
-- from leaking permanently.
function _M.acquire(prefix, max, ttl)
  if not max or max < 1 then
    return nil
  end

  for i = 1, max do
    local ok = ngx.shared.auto_ssl:add(prefix .. i, true, ttl)
    if ok then
      return i
    end
  end

  return nil
end

function _M.release(prefix, slot)
  if slot then
    ngx.shared.auto_ssl:delete(prefix .. slot)
  end
end

return _M
