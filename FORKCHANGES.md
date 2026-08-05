
## Fork changes

### Remove OCSP stapling support

OCSP stapling has been dropped (`ocsp_stapling_error_level` option, `get_ocsp_response`/`set_ocsp_stapling` in `ssl_certificate.lua`, and the `ngx.ocsp` dependency). Most CAs have deprecated or fully shut down OCSP in favor of CRLs, so this code path was querying infrastructure that increasingly no longer exists:

- CA/Browser Forum made OCSP optional for CAs (and CRLs mandatory) starting March 2024.
- Let's Encrypt announced its OCSP shutdown in December 2024 and completed it on August 6, 2025 — its OCSP responders are offline and certificates no longer include OCSP URLs.

References:
- https://letsencrypt.org/2024/12/05/ending-ocsp
- https://letsencrypt.org/2025/08/06/ocsp-service-has-reached-end-of-life
- https://community.letsencrypt.org/t/ending-ocsp-support-in-2025/229786


PR: [####1](https://github.com/ubmagh/lua-resty-auto-ssl/pull/1)

---

### CI fixes

Bumped the OpenResty base images used by the GitHub Actions test matrix (`centos`, `ubuntu`, `alpine`), which had been pinned for years and had accumulated several dead external dependencies along the way. `openresty1.13` and `lua51` were left on their original old pinned versions, since those two variants exist specifically to test backward compatibility with older OpenResty releases.

Fixed one broken dependency at a time as they surfaced:

- **Dead `git://` protocol** — `luarocks-fetch-gitrec` clones over the raw git protocol (port 9418), which GitHub silently drops connections on since deprecating it. Fixed with a global `git config url."https://github.com/".insteadOf git://github.com/` rewrite.
- **Dead CentOS 7 mirrors** — `mirrorlist.centos.org`/`mirror.centos.org` no longer serve CentOS 7 (EOL), so `yum` couldn't resolve any repo. Rewritten to `vault.centos.org` via `sed` on the repo files.
- **Alpine's `lua` package** — no longer ships a plain `/usr/bin/lua` binary (only `lua5.1` does), which broke building the `process` rock. Switched to installing `lua5.1` explicitly.
- **`sockproc` build failure** — the vendored `sockproc.c` (fetched at build time) has a K&R-style `proc_exit()` prototype that modern GCC rejects under `-Werror`. Switched the source to [communiteq/sockproc](https://github.com/communiteq/sockproc), a maintained fork with that exact fix applied upstream.
- **LuaRocks manifest too large for old Lua 5.1** — the LuaRocks bundled in the old pinned `openresty1.13`/`lua51` images predates a fix (LuaRocks 3.12) for the public manifest outgrowing Lua 5.1's 65536-constants-per-chunk bytecode limit. Built LuaRocks 3.13.0 from source against the bundled LuaJIT for those two variants only.
- **Old GCC rejects C99 syntax** — the same `openresty1.13`/`lua51` images ship a GCC that defaults to `gnu89`, which rejects the C99-style `for` loop declarations used by `luasystem` (a transitive `busted` dependency). Set `luarocks config variables.CFLAGS "-O2 -fPIC -std=gnu99"` for those two variants.
- **Expired fallback test fixture** — `spec/certs/example_fallback.crt` was a static, self-signed dummy cert generated in 2016 with a 10-year validity window, which lapsed on 2026-03-27. Any test that fell back to it (for any reason) failed with a misleading "certificate has expired" error, unrelated to the actual cert/domain under test. Regenerated with a fresh far-future expiry (2046).
- **ngrok free tier no longer usable** — it intercepts ACME HTTP-01 challenges on its own managed dev-domain, so real Let's Encrypt issuance could never complete. Replaced ngrok with Cloudflare Tunnel (`cloudflared` quick tunnels) across all 5 Docker images and the test harness — anonymous, no account/token required, and the challenge path passes through untouched.
- **Unpinned `cloudflared` version** — the initial Cloudflare Tunnel install used a different unpinned method per distro (yum repo, apt repo, GitHub `releases/latest`), so the 5 images could silently drift to different `cloudflared` builds depending on build time. Standardized all 5 Dockerfiles on the same pinned GitHub release binary.
- **`dehydrated` requires `hexdump`, which none of the images installed** — dehydrated checks for it at startup and exits immediately if it's missing, before attempting any ACME work at all. This single missing binary was silently causing every cert-issuing test to fail (falling back to the self-signed fallback cert, missing working directories dehydrated never got to create, mismatched error-text assertions for scenarios never reached) despite looking like several unrelated bugs. Added the package that provides it per distro: `util-linux` (the 3 CentOS-based images), `bsdextrautils` (ubuntu), `hexdump` (alpine).
- **Stale Let's Encrypt staging trust bundle** — `spec/certs/letsencrypt_staging_chain.pem` (used by the test harness to trust Let's Encrypt's staging root, since staging certs aren't in any public trust store) hardcoded the 2016-era `Fake LE Root X1`/`Fake LE Intermediate X1` pair. Let's Encrypt has since rotated staging to entirely different, cryptographically unrelated roots (`(STAGING) Pretend Pear X1` and others). Once real issuance started succeeding (after the `hexdump` fix), every verification failed with `unable to get local issuer certificate` since the bundled trust file didn't match. Rebuilt it from the 4 currently-active staging roots published by Let's Encrypt.
- Follow-up cleanup of 1st PR: `http_proxy_options` was only ever documented and used for routing OCSP stapling requests through a proxy. With OCSP gone, it had no remaining consumer anywhere in `lib/`. Removed it from the README and deleted `spec/proxy_spec.lua`, which only existed to test that dead option.
- **Frozen CA trust bundle on the old `openresty1.13`/`lua51` images** — their bundled CA store predates Let's Encrypt's 2025 root rotation entirely, so `curl` can't verify most of the modern internet from inside them, including `luarocks.org` and `github.com`. Bootstrapped a current CA bundle from `curl.se` (one narrowly-scoped insecure fetch, since even that source chains through the same new root) and overwrote the system trust store with it, instead of disabling verification on every subsequent request.
- **`luarocks config` misparsing its own value** — `luarocks config variables.CFLAGS "-O2 -fPIC -std=gnu99"` failed because the value starts with a dash, so LuaRocks' CLI parser read it as an attempt to pass options rather than the value. Fixed with the standard `--` end-of-options marker: `luarocks config -- variables.CFLAGS "..."`.
- **`memory_spec.lua` assumed a memory-pressure scenario that no longer reliably applies** — this test cram-fills the shared dict with large (256000-byte) items to force eviction, then expects a *small* subsequent cert-cache write (the real fullchain/privkey DER data, only a few KB) to also force eviction and log a warning. Those two very different sizes likely land in different slab size-classes, and newer nginx shared-dict allocators (bundled in the bumped images) reuse freed space across size classes efficiently enough that the small write no longer reliably needed to evict anything, even with the large dict completely full. Made the `auto_ssl` shared dict's size overridable per-test (`auto_ssl_dict_size` template variable, defaulting to the existing `1m`) and sized it down to `64k` for this test specifically, with filler items closer in size to real cert DER data — so eviction is forced deterministically regardless of allocator size-class behavior, rather than depending on it.
- **`git://` protocol fix never made it to `lua51`/`openresty1.13`** — the dead-`git://`-protocol fix (see above) was only ever applied to `centos`/`ubuntu`/`alpine`; these two were still blocked on earlier issues (yum mirrors, CA bundle) when that fix landed, so it never got a chance to surface for them until now. Added it to both.
- **"self signed" vs "self-signed" wasn't just a typo — it's two different OpenSSL versions** — `lua51`/`openresty1.13` are deliberately never bumped, so they still bundle an older OpenSSL that phrases this verify error without a hyphen, while the bumped images' newer OpenSSL uses one. The 14 assertions hardcoding the exact string only ever matched one or the other. Switched them from an exact string match to a pattern (`"^18: self.signed certificate$"`) checking the stable part — the numeric error code — instead of pinning OpenSSL's exact wording, which is free to vary release to release.

PR: [####2](https://github.com/ubmagh/lua-resty-auto-ssl/pull/2)

---

### Features & cutomizations: wave #1

- **Configurable storage TTLs** — ACME challenge tokens and cached certs can now actually expire in storage instead of persisting indefinitely. Best suited to the Redis storage adapter, since the file adapter's `ngx-timer`-based expiry doesn't hold up for long TTLs (see below). Five related options, and they interact — read all of them before changing any one:

  - `challenge_keys_exptime` (default `3600`, 1h) — TTL for ACME challenge tokens. Independent of everything below.
  - `ssl_certs_keys_exptime` (default `7776000`, 90 days) — the nominal cert TTL, only used as-is by mode `1`.
  - `ssl_certs_keys_expire_mode` (default `2`) — how the cert TTL is actually computed:
    - `0`: no TTL, cert entries never expire.
    - `1`: flat TTL — always `ssl_certs_keys_exptime` (minus the renewal buffer below).
    - `2`: dynamic TTL — computed from each cert's *actual* expiry date instead of the flat default, so storage cleans itself up right around when that specific cert would expire anyway, regardless of what CA or profile issued it.
  - `renew_offset_ssl_certs_exptime` (default `86400`, 1 day) — subtracted from the computed TTL (both modes `1` and `2`), so storage expires *before* the cert is actually dead, leaving the renewal job a buffer to replace it first. Without this, storage could self-delete right as the cert becomes invalid, racing the renewal cycle instead of giving it room to succeed.
  - `min_ssl_certs_exptime` (default `86400`, 1 day) — floor applied if the subtraction above goes to zero or negative (e.g. a cert already within its buffer window of real expiry when cached, or `ssl_certs_keys_exptime` set smaller than the buffer). Deliberately small: the failure mode this guards against is a near-dead cert getting served from cache far longer than it's actually valid, not storage cleaning up a little early.

  ```lua
  auto_ssl:set("challenge_keys_exptime", 3600)             -- 1 hour
  auto_ssl:set("ssl_certs_keys_exptime", 7776000)          -- 90 days, only used as-is by mode 1
  auto_ssl:set("ssl_certs_keys_expire_mode", 2)            -- 0 = no TTL, 1 = flat TTL, 2 = per-cert expiry (default)
  auto_ssl:set("renew_offset_ssl_certs_exptime", 86400)    -- buffer subtracted from the TTL for renewal to catch up
  auto_ssl:set("min_ssl_certs_exptime", 86400)             -- floor when that subtraction goes non-positive
  ```

- **Case-insensitive domain keys in storage** — domains are now normalized to lowercase everywhere they touch storage (cache keys, storage keys, renewals, issuance), instead of only in some code paths. Requests for the same domain in different cases (`Example.com` vs `example.com`) now share one cert/cache entry instead of each triggering its own issuance.

- **Redis connection lifecycle fix, plus configurable timeouts/keepalive** — the Redis adapter previously never released connections back to the pool correctly: it tried to `set_keepalive` *before* connecting (a no-op, since there's nothing to keep alive yet) and cached the connection in `ngx.ctx` for reuse across a request without ever releasing it afterward, so it just leaked at the end of each request instead of being pooled. Fixed by opening one connection per operation and explicitly releasing it right after that operation completes — deterministic, and doesn't depend on every call site remembering to clean up (which is easy to miss across early-return error paths). Also added `timeouts` and `keepalive` options, previously hardcoded.

  ```lua
  auto_ssl:set("redis", {
    host = "127.0.0.1",
    port = 6379,
    timeouts = {
      conn = 3000,  -- connect timeout, ms
      send = 3000,  -- send timeout, ms
      read = 3000,  -- read timeout, ms
    },
    keepalive = {
      keepalive_duration = 300000, -- max idle time in the pool, ms (5 min, check `timeout` setting on redis-side)
      pool_size = 10,              -- max pooled connections per nginx worker
    },
  })
  ```

- **Configurable renewal threshold** — new `renew_age_days` option (default `30`, matching the previous hardcoded behavior) controls how close to expiry a cert needs to be before the renewal job renews it, instead of that window being fixed at 30 days. Takes a plain day count, converted to seconds where it's actually used — unlike the `_exptime`/`_ssl_certs_exptime` options above, which all take raw seconds.

  ```lua
  auto_ssl:set("renew_age_days", 30) -- renew once a cert is within this many days of expiring
  ```

- **Manually-triggerable renewal, and an option to disable the internal schedule** — `renewal.lua`'s renewal cycle is now exposed as `require("resty.auto-ssl.jobs.renewal").do_renew(auto_ssl_instance)`, so it can be called on demand (e.g. from a vhost endpoint), instead of only ever running on `auto_ssl`'s own internal recursive timer. New `enable_internal_renew_schedule` option (default `true`) lets that internal timer be turned off entirely for setups that want to drive renewal purely through their own external trigger (cron, admin endpoint, etc.).

  Important: manual and internal-scheduled renewals share the *same* rate-limiting lock, held for `renew_check_interval` (default 1 day) regardless of which one acquired it. This is intentional, not a bug to work around — the goal is one predictable, once-per-interval renewal cadence system-wide, no matter what triggers it. Practical effect: calling the manual trigger will no-op (logs `can't launch renew, renewal-state is locked for another worker`) if a renewal already ran — from either source — within the last `renew_check_interval`. If you want manual triggers to run more freely, lower `renew_check_interval` itself rather than expecting the two paths to have independent budgets.

  ```lua
  auto_ssl:set("enable_internal_renew_schedule", false) -- rely entirely on your own external trigger instead
  ```

  ```lua
  -- from your own vhost/endpoint (assumes `auto_ssl` was assigned as a global
  -- in init_by_lua_block, per this project's own README example):
  local renewal = require "resty.auto-ssl.jobs.renewal"
  renewal.do_renew(auto_ssl)
  ```

- **Log messages tagged with their module, for easier filtering** — `ngx.log` calls across the library now read `[auto-ssl][<module>]: ...` (e.g. `[auto-ssl][renewal]:`, `[auto-ssl][redis_storage]:`) instead of a flat `auto-ssl: ...` prefix, so production logs can be filtered per subsystem. A couple of messages that a test still asserts on verbatim (`sanity_spec.lua`) were deliberately left in the old format rather than touched. For the messages that *did* change, rather than hardcode the new prefix into the affected spec assertions (just recreating the same fragility for next time), they were loosened to match the meaningful substring only — the same pattern several assertions already used — so they're robust against this kind of prefix change happening again.

  A subset of these are tagged `[auto-ssl][<module>-debug]:` and logged at `ngx.ERR` deliberately, not by mistake — they're meant for monitoring/dashboards, and `ngx.ERR` is the only level guaranteed to show up regardless of a deployment's configured `error_log` verbosity (nginx's own default minimum is `error`, so anything less severe can silently go missing depending on setup). That collided with the many `assert.Not.matches("[error]", ...)`-style checks across the spec suite, which treat any `[error]`-tagged line as an unexpected failure. Rather than weaken the log level (defeating the point) or touch the ~116 assertions individually, `spec/support/log_tail.lua`'s shared log-reading function now strips lines matching `[auto-ssl][*-debug]:` before the content reaches any assertion — every existing check across the suite is covered from that one place, and a genuine unrelated `[error]` line still fails a test as it should.

##### New options at a glance

| Option | Default | Purpose |
| --- | --- | --- |
| `challenge_keys_exptime` | `3600` (1h) | TTL for ACME challenge tokens in storage. |
| `ssl_certs_keys_exptime` | `7776000` (90d) | Nominal cert TTL; only used as-is by expire mode `1`. |
| `ssl_certs_keys_expire_mode` | `2` | `0` no TTL, `1` flat TTL, `2` dynamic (per-cert expiry). |
| `renew_offset_ssl_certs_exptime` | `86400` (1d) | Buffer subtracted from the cert TTL so storage expires before the cert, giving renewal room to catch up. |
| `min_ssl_certs_exptime` | `86400` (1d) | Floor for the TTL if the subtraction above goes non-positive. |
| `renew_age_days` | `30` | How close to expiry (in days) before the renewal job renews a cert. |
| `enable_internal_renew_schedule` | `true` | Set `false` to disable the internal recursive renewal timer entirely (e.g. to drive renewal only via your own external trigger). |
| `redis` → `timeouts.conn/send/read` | `3000`/`3000`/`3000` (ms) | Redis connect/send/read timeouts. |
| `redis` → `keepalive.keepalive_duration/pool_size` | `300000` ms / `10` | Redis connection pool idle timeout and size, per nginx worker. |

Also new: `require("resty.auto-ssl.jobs.renewal").do_renew(auto_ssl)`, an exposed function (not a config option) to manually trigger a renewal cycle on demand.

- **`lua-resty-redis`'s `set_timeouts()` doesn't exist on the two old pinned images** — `openresty1.13`/`lua51` bundle lua-resty-redis 0.25/0.26, and the 3-argument `set_timeouts(conn, send, read)` wasn't added until v0.28 (2020) — calling it unconditionally threw a hard Lua error there ("attempt to call a nil value"), which showed up as a genuine `[error]` failing Redis-adapter tests on those two variants specifically. `redis.lua` now checks whether `connection.set_timeouts` exists before calling it, falling back to the older single-value `set_timeout(ms)` (using the largest of the three configured values) when it doesn't.
- **Intermittent ACME `NXDOMAIN` failures against the Cloudflare tunnel** — `cloudflared` itself warns that a freshly-announced quick tunnel "may take some time to be reachable": its hostname gets printed to the log before the DNS record has necessarily propagated publicly. The test harness extracted that hostname and immediately started issuing real certs against it, so Let's Encrypt's own validator would occasionally hit the domain before its DNS record had actually propagated, failing with a genuine `NXDOMAIN` unrelated to any of our code (hit both file- and Redis-adapter tests identically, since it happens before either adapter is even reached). `spec/support/server.lua` now polls the tunnel over real HTTPS until it actually responds before letting the rest of the suite proceed, instead of trusting the announcement alone.
- **Noisy, harmless `[error]` lines from ngx_lua's own cosocket logging on `openresty1.13`** — `"attempt to send data on a closed socket: u:0000..., c:0000..."` flooded the log around `sockproc` startup on that image specifically, failing the suite's blanket "no unexpected `[error]`" checks. Traced to `ngx_http_lua_socket_tcp_send` in `lua-nginx-module` itself: both the `u`/`c` pointers are null in every occurrence, meaning `:send()` is being invoked on a cosocket that was never actually connected or was already torn down — a known, generic ngx_lua diagnostic, not a resolver or kernel compatibility issue (functionality wasn't actually affected; cert issuance completed successfully in the same runs). ngx_lua's own docs recommend disabling this specific log line (`lua_socket_log_errors off;`) once your own Lua code already checks cosocket connect/send errors itself, which every call site in this codebase does. Rather than apply that suite-wide, added a new `TEST_NGINX_SUPPRESS_SOCKET_LOG_ERRORS` env var (set in the `openresty1.13`/`lua51` Dockerfiles only, same pattern as the existing per-image `TEST_NGINX_RESOLVER`) so the test `nginx.conf` only disables this logging on the two old images where it's actually been observed, leaving full error visibility everywhere else.

PR: [####3](https://github.com/ubmagh/lua-resty-auto-ssl/pull/3)

---

### Features & cutomizations: wave #2

//
