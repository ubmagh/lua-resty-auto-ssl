# Driving renewals from a vhost (recommended)

Renewals can run two ways:

- **Internal timer** (default, `enable_internal_renew_schedule = true`): every worker keeps a recursive timer that calls the renewal sweep every `renew_check_interval`.
- **Endpoint-driven** (recommended): turn the timer off and trigger the sweep through a small, dedicated vhost, called by cron or your own scheduler.

## Why the endpoint is better

- **Control.** Trigger a sweep on demand, or stop a running one with `stop_renewal()` (see [FORKCHANGES.md](FORKCHANGES.md#wave-6)) — no killing workers, no stale locks.
- **Survives reloads and deploys.** The internal timer restarts on every nginx start/reload and waits a full `renew_check_interval` before its first run, so frequent deploys can starve it. A cron schedule doesn't care.
- **Separate logs.** The vhost can have its own `access_log` (who triggered/stopped what, when), and the sweep's own lines are all tagged `[auto-ssl][renewal...]`, so they're easy to split into their own file. A server-level `error_log` may capture them too — check that on your nginx build.
- **You pick when and where it runs.** Off-peak hours, or from a single node when several nginx servers share one Redis (otherwise each one sweeps on its own).
- **Visible failures.** The caller gets an HTTP status, so a cron/monitor can alert on a failed or skipped run.
- **Metrics cadence.** With `enable_storage_metrics_logging`, metrics are logged whenever the sweep is triggered. Calling the endpoint more often than `renew_check_interval` plus a short `storage_metrics_log_interval` gives them their own cadence (the sweep itself stays limited by `renew_check_interval`).

## Trade-offs

- **Something has to call it.** If the scheduler stops, nothing renews. Alert on cert expiry (e.g. the `exp20` count from `enable_storage_metrics_logging`), and consider keeping `enable_on_demand_renewal = true` as a safety net.
- **Protect the endpoint.** Anyone who can reach it can start a sweep (the interval lock limits it to one per `renew_check_interval`, but each sweep can use ACME quota). Keep it on an internal address.

## Setup

```lua
local auto_ssl = (require "resty.auto-ssl").new({
  enable_internal_renew_schedule = false,
  renew_check_interval = 3600, -- minimum seconds between sweeps; triggers inside this window are skipped
  -- ...
})
```

```nginx
server {
  listen 127.0.0.1:9100;   # internal only
  access_log /var/log/nginx/auto-ssl-renewal.access.log;

  location /trigger-renewal {
    content_by_lua_block {
      local auto_ssl = require("resty.auto-ssl").singleton_instance
      if not auto_ssl then
        ngx.status = 500
        ngx.say("500- Failed to get auto-ssl instance")
        return
      end

      -- interval lock still held: do_renew would silently skip
      if ngx.shared.auto_ssl:get("lock:renew") then
        ngx.status = 429
        ngx.say("429- Renewal already ran within renew_check_interval, skipping")
        return
      end

      local renewal_job = require "resty.auto-ssl.jobs.renewal"
      local ok, err = ngx.timer.at(3, function(premature)
        if premature then return end
        local ran, run_err = pcall(renewal_job.do_renew, auto_ssl)
        if not ran then
          ngx.log(ngx.ERR, "[auto-ssl][trigger-debug]: failed to run renewal: ", run_err)
        end
      end)
      if not ok then
        ngx.status = 500
        ngx.say("500- Failed to schedule renewal: ", err)
        return
      end

      ngx.say("200- Renewal job dispatched !")
    }
  }

  location /stop-renewal {
    content_by_lua_block {
      local state, err = require("resty.auto-ssl.jobs.renewal").stop_renewal()
      if not state then
        ngx.status = 500
        ngx.say("500- Failed to request stop: ", err)
        return
      end
      ngx.say("200- ", state == "stopping" and "Stop requested; the sweep halts after the domain in progress"
                                             or "No sweep running; leftover locks cleared")
    }
  }

  location / {
    return 404;
  }
}
```

Then schedule the trigger **less often** than `renew_check_interval` (the lock is taken a few seconds after the call, so an equal period can land inside it and get a 429), e.g. every 6 hours with cron:

```
0 */6 * * * curl -fsS http://127.0.0.1:9100/trigger-renewal
```

`-f` makes curl fail on a 429/500, so cron can alert. Only certs inside `renew_age_days` are actually renewed, so a sweep every few hours is plenty, and it retries earlier failures.
