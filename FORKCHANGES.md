
## Fork changes

### Remove OCSP stapling support

Dropped OCSP stapling (`ocsp_stapling_error_level`, `get_ocsp_response`/`set_ocsp_stapling` in `ssl_certificate.lua`, the `ngx.ocsp` dependency). Most CAs have deprecated or shut down OCSP in favor of CRLs, so this was querying infrastructure that increasingly doesn't exist: CA/Browser Forum made OCSP optional (CRLs mandatory) starting March 2024, and Let's Encrypt completed its own OCSP shutdown August 6, 2025.

References: [LE ending OCSP](https://letsencrypt.org/2024/12/05/ending-ocsp) · [OCSP EOL](https://letsencrypt.org/2025/08/06/ocsp-service-has-reached-end-of-life) · [community thread](https://community.letsencrypt.org/t/ending-ocsp-support-in-2025/229786)

PR: [####1](https://github.com/ubmagh/lua-resty-auto-ssl/pull/1)

---

### CI fixes

Bumped the OpenResty base images for `centos`/`ubuntu`/`alpine` (pinned for years, dead dependencies had piled up). `openresty1.13`/`lua51` stay on their original old versions deliberately — they exist to test backward compat. Fixed one broken dependency at a time as they surfaced:

- **Dead `git://` protocol** — GitHub dropped it; `luarocks-fetch-gitrec` needed a `git config url.".insteadOf git://` rewrite to `https://`.
- **Dead CentOS 7 mirrors** — `mirrorlist.centos.org` is gone (EOL); rewritten to `vault.centos.org`.
- **Alpine's `lua` package** — no longer ships plain `/usr/bin/lua`; switched to `lua5.1` explicitly.
- **`sockproc` build failure** — vendored source's K&R prototype rejected by modern GCC; switched to the [communiteq/sockproc](https://github.com/communiteq/sockproc) fork with the fix upstream.
- **LuaRocks manifest too large for old Lua 5.1** — hit the bytecode constants-per-chunk limit; built LuaRocks 3.13.0 from source for the two pinned images.
- **Old GCC rejects C99** — `gnu89`-default GCC on the two pinned images chokes on `luasystem`'s C99 `for` loops; set `CFLAGS=-std=gnu99`.
- **Expired fallback fixture** — the static self-signed `example_fallback.crt` lapsed 2026-03-27; regenerated with a 2046 expiry.
- **ngrok unusable** — it intercepts ACME HTTP-01 challenges on its own domain; replaced with Cloudflare Tunnel across all 5 images and the test harness.
- **Unpinned `cloudflared`** — install method varied per distro; standardized on one pinned GitHub release binary everywhere.
- **Missing `hexdump`** — dehydrated hard-requires it at startup and silently aborts without it, masquerading as several unrelated failures; added the package providing it per distro.
- **Stale LE staging trust bundle** — hardcoded 2016-era staging roots no longer match LE's rotated staging chain; rebuilt from the 4 currently-active roots.
- **`http_proxy_options` cleanup** — dead option, only ever used for OCSP proxying; removed from README, deleted its now-pointless spec.
- **Frozen CA bundle on the two pinned images** — predates LE's 2025 root rotation, breaking `curl` to `luarocks.org`/`github.com`; bootstrapped a fresh bundle from `curl.se`.
- **`luarocks config` dash-parsing bug** — a value starting with `-` was misread as a flag; fixed with the `--` end-of-options marker.
- **`memory_spec.lua`'s eviction assumption went stale** — newer nginx shared-dict allocators no longer reliably evict a small write after a large fill; made the dict size overridable per-test and shrunk it with right-sized filler for this test.
- **`git://` fix missed two images** — the fix above only reached `centos`/`ubuntu`/`alpine` initially (the other two were still blocked on earlier issues); added there too.
- **"self signed" vs "self-signed"** — different OpenSSL versions on old vs. bumped images phrase this error differently; switched 14 assertions from exact-string to matching the stable numeric error code instead.

PR: [####2](https://github.com/ubmagh/lua-resty-auto-ssl/pull/2)

---

### Features & cutomizations: wave #1

- **Configurable storage TTLs** — certs/challenges can now actually expire in storage. Best suited to Redis (the file adapter's timer-based expiry doesn't hold up for long TTLs). Five options that interact — read together:
  - `challenge_keys_exptime` (`3600`, 1h) — challenge token TTL, independent of the rest.
  - `ssl_certs_keys_exptime` (`7776000`, 90d) — nominal cert TTL, only used as-is by mode `1`.
  - `ssl_certs_keys_expire_mode` (`2`) — `0` no TTL, `1` flat TTL, `2` dynamic (per-cert real expiry).
  - `renew_offset_ssl_certs_exptime` (`86400`, 1d) — buffer subtracted so storage outlives the cert, giving renewal room to replace it first.
  - `min_ssl_certs_exptime` (`86400`, 1d) — floor if that subtraction goes non-positive.

  ```lua
  auto_ssl:set("challenge_keys_exptime", 3600)
  auto_ssl:set("ssl_certs_keys_exptime", 7776000)
  auto_ssl:set("ssl_certs_keys_expire_mode", 2)
  auto_ssl:set("renew_offset_ssl_certs_exptime", 86400)
  auto_ssl:set("min_ssl_certs_exptime", 86400)
  ```

- **Case-insensitive domain keys** — domains are normalized to lowercase everywhere storage is touched, so `Example.com`/`example.com` share one cert instead of double-issuing.

- **Redis connection lifecycle fix + configurable timeouts/keepalive** — connections used to leak (a `set_keepalive` called *before* connecting, then cached in `ngx.ctx` and never released). Now one connection per operation, released deterministically right after. Added `timeouts`/`keepalive` options, previously hardcoded:

  ```lua
  auto_ssl:set("redis", {
    host = "127.0.0.1", port = 6379,
    timeouts = { conn = 3000, send = 3000, read = 3000 },
    keepalive = { keepalive_duration = 300000, pool_size = 10 },
  })
  ```

- **Configurable renewal threshold** — `renew_age_days` (default `30`) replaces the previously-fixed 30-day renewal window: `auto_ssl:set("renew_age_days", 30)`.

- **Manually-triggerable renewal + schedule disable** — `require("resty.auto-ssl.jobs.renewal").do_renew(auto_ssl)` runs a renewal cycle on demand. New `enable_internal_renew_schedule` (default `true`) turns off the internal recursive timer for setups driving renewal purely externally. Manual and scheduled renewals share the same `renew_check_interval` rate-limiting lock by design — one predictable cadence regardless of trigger; lower `renew_check_interval` if you want manual triggers to run more freely.

  ```lua
  auto_ssl:set("enable_internal_renew_schedule", false)
  local renewal = require "resty.auto-ssl.jobs.renewal"
  renewal.do_renew(auto_ssl)
  ```

- **Module-tagged log messages** — `ngx.log` calls now read `[auto-ssl][<module>]: ...` instead of a flat `auto-ssl: ...` prefix, filterable per subsystem (a couple of `sanity_spec.lua`-asserted messages were deliberately left alone). Assertions were loosened to match the meaningful substring rather than the full prefix, so future prefix changes don't re-break them. A `[auto-ssl][<module>-debug]:` subset is deliberately logged at `ngx.ERR` (the only level guaranteed visible regardless of configured `error_log` verbosity) for monitoring/dashboards — `spec/support/log_tail.lua` strips those lines before any assertion sees them, so genuine `[error]` lines still fail tests as expected.

##### New options at a glance

| Option | Default | Purpose |
| --- | --- | --- |
| `challenge_keys_exptime` | `3600` (1h) | TTL for ACME challenge tokens in storage. |
| `ssl_certs_keys_exptime` | `7776000` (90d) | Nominal cert TTL; only used as-is by expire mode `1`. |
| `ssl_certs_keys_expire_mode` | `2` | `0` no TTL, `1` flat TTL, `2` dynamic (per-cert expiry). |
| `renew_offset_ssl_certs_exptime` | `86400` (1d) | Buffer subtracted from the cert TTL so storage expires before the cert. |
| `min_ssl_certs_exptime` | `86400` (1d) | Floor for the TTL if that subtraction goes non-positive. |
| `renew_age_days` | `30` | How close to expiry (days) before renewal kicks in. |
| `enable_internal_renew_schedule` | `true` | `false` disables the internal recursive renewal timer. |
| `redis` → `timeouts.conn/send/read` | `3000`/`3000`/`3000` (ms) | Redis connect/send/read timeouts. |
| `redis` → `keepalive.keepalive_duration/pool_size` | `300000` ms / `10` | Redis pool idle timeout and size, per worker. |

Also new: `require("resty.auto-ssl.jobs.renewal").do_renew(auto_ssl)` — manual renewal trigger (not a config option).

- **`lua-resty-redis`'s `set_timeouts()` missing on the two old pinned images** — bundled 0.25/0.26 predates it (added in v0.28); `redis.lua` now checks for it and falls back to `set_timeout(ms)` with the largest configured value.
- **Intermittent ACME `NXDOMAIN` against the Cloudflare tunnel** — a freshly-announced quick tunnel's hostname can be printed before its DNS record propagates; `spec/support/server.lua` now polls over real HTTPS until it actually responds first.
- **Noisy harmless `[error]` cosocket logging on `openresty1.13`** — a known ngx_lua diagnostic (`:send()` on a never-connected/torn-down cosocket around sockproc startup), not a real failure. New `TEST_NGINX_SUPPRESS_SOCKET_LOG_ERRORS` env var (set only on the two old images, same pattern as `TEST_NGINX_RESOLVER`) disables just that log line there.

PR: [####3](https://github.com/ubmagh/lua-resty-auto-ssl/pull/3)

---

### Features & cutomizations: wave #2

- **`has_certificate()` missed wave #1's case-insensitive normalization** — every other domain-touching path lowercases before touching storage; this public helper didn't, so a mixed-case caller could get a false "no cert" for an already-cached domain. Now lowercases first.

  ```lua
  local has_cert = auto_ssl:has_certificate("Example.com") -- now matches the "example.com" entry
  ```

- **`enable_internal_renew_schedule = false` was silently ignored when passed to `.new()`** — the wave #1 default used `if not options[...]`, which in Lua treats `false` the same as unset, silently resetting it back to `true`. Only worked via `auto_ssl:set(...)` after construction. Fixed to check `== nil`; added a spec test, since none existed.

  ```lua
  auto_ssl = (require "resty.auto-ssl").new({
    dir = "/etc/resty-auto-ssl",
    enable_internal_renew_schedule = false, -- now actually takes effect
  })
  ```

- **Redis adapter: skip re-auth on pooled connections, silently retry a stale one** — `AUTH`/`SELECT` used to run on every operation even on a reused pooled connection; now skipped via `connection:get_reused_times()`, saving 2 round trips per op when `redis.auth`/`redis.db` are set. A connection closed by the far end while idle in the pool now gets one silent retry on a fresh connection (every op here is naturally idempotent) instead of logging a failure — and a broken connection is always `close()`'d rather than handed back, which also removes a second, redundant "failed to set keepalive" log line that used to follow the real error. Not covered by a spec test (would need a real idle timeout on the *shared* test Redis instance, affecting every other spec file).

- **Redis adapter: optional sorted-set index for renewal** — the renewal job used to `KEYS`-scan every stored cert every cycle. New `enable_redis_sorted_list_renewal` (default `false`, opt-in) maintains a Redis sorted set (`certs_zset_store`) scored by real cert expiry (`set_cert`/`delete_cert` keep it current via `ZADD`/`ZREM`), so renewal fetches only domains actually due via `ZRANGEBYSCORE`. Refined before shipping: scored by the cert's real expiry (`cert_expiry_ts`) rather than derived from storage TTL, so mode `0` ("no TTL") certs — which have no TTL to derive from — aren't silently excluded, and challenge/lock keys don't pollute the set; the set's own name is now `prefixed_key()`'d too, so two `prefix`-scoped instances sharing one db don't collide on it. Defaulted off since it's new code on the core renewal path. **Turn it on as early as possible** — only certs that existed *before* it was enabled need the migration scripts below at all.

  ```lua
  auto_ssl:set("enable_redis_sorted_list_renewal", true) -- requires the redis storage adapter
  ```

- **`scripts/backfill_certs_expiry.sh`** — run first. Backfills a missing `expiry` field (certs from an old enough version of this library) by reading the real `notAfter` off the cert's own `fullchain_pem`, preserving the key's existing TTL. `DRY_RUN=true` by default.
- **`scripts/populate_sorted_list.sh`** — run second. `SCAN`s existing `<domain>:latest` keys and `ZADD`s each into the sorted set from its stored `expiry`; skips (warns) anything missing one.
- **`manual-test/`** — a Docker Compose setup for exercising both of the above by hand, including real issuance via a `cloudflared` tunnel. See `manual-test/README.md`.

##### New options at a glance

| Option | Default | Purpose |
| --- | --- | --- |
| `enable_redis_sorted_list_renewal` | `false` | Redis only. Sorted-set renewal index, opt-in. |

Also new, not config options: the two migration scripts above (run in that order), and `manual-test/`.

PR: [####4](https://github.com/ubmagh/lua-resty-auto-ssl/pull/4)

---

### Features & cutomizations: wave #3

- **Configurable `issue_cert_lock` timing** — the storage-backed distributed issuance lock had three hardcoded values (wait time, poll interval, hold duration), now all options with defaults matching prior behavior. Worth raising if your CA is slow/rate-limited: too-short `issue_cert_lock_exptime` lets the lock expire mid-issuance, starting a redundant concurrent attempt for the same domain; too-short `issue_cert_lock_wait_time` makes other concurrent requests give up waiting and issue redundantly too.

  ```lua
  auto_ssl:set("issue_cert_lock_wait_time", 90)
  auto_ssl:set("issue_cert_lock_poll_interval", 0.5)
  auto_ssl:set("issue_cert_lock_exptime", 120)
  ```

- **Imported from [negrusti/lua-resty-auto-ssl](https://github.com/negrusti/lua-resty-auto-ssl)** (adapted against this fork's current state, not cherry-picked — log prefixes, the sorted-list feature, etc. had already diverged). Commits: [4921caa](https://github.com/negrusti/lua-resty-auto-ssl/commit/4921caa7a1c215865eb7629f828bd73d7a7f5a21), [98d16d0](https://github.com/negrusti/lua-resty-auto-ssl/commit/98d16d0d1fa37d5e553a69ac8a5f594b99ee3815), [9befd92](https://github.com/negrusti/lua-resty-auto-ssl/commit/9befd92d20562cb8fdb61f94e7513dbb153f0084), [2c09659](https://github.com/negrusti/lua-resty-auto-ssl/commit/2c096596c09aeb9db06600624a4dd04aaa1e3b10), [8c73530](https://github.com/negrusti/lua-resty-auto-ssl/commit/8c73530ce47a1aca862c8ca2ac495ade2091340e), [7025227](https://github.com/negrusti/lua-resty-auto-ssl/commit/7025227c54dbc0773656c94a83f5bec1eb878ca0):

  - **Renewal's `mkdir`/`openssl` now go through the non-blocking sockproc path** (`shell_execute`) instead of `shell-games`'s blocking `io.popen`, matching how dehydrated itself is already invoked — avoids stalling the worker from inside the `ngx.timer`-driven renewal job. Needed an explicit `result["status"] ~= 0` check, since `shell_execute`'s error contract differs. Side effect: the certs dir's permissions now follow sockproc's own umask instead of a pinned `0022` — low-risk, that dir only ever holds the public `cert.pem`.
  - **On-demand renewal** — the serving path never checked expiry at all, only cert existence, so a domain could sit past its renewal window until the next periodic sweep reached it. New opt-in `enable_on_demand_renewal` (default `false`) hooks into `get_cert_der`'s storage-lookup path (not the shmem-cache-hit fast path): a served cert within `renew_age_days` of expiring (or expired, or missing an expiry) fires a non-blocking background renewal for just that domain (`renewal.renew_domain()`), zero added latency on the current request. A dedup lock (`renew_trigger_dedup_time`, `600`s) throttles re-triggering; success clears the DER cache so the next request picks up the fresh cert immediately.
  - **Concurrency caps, each independently opt-in** — `renew_max_concurrency`/`issue_max_concurrency` (both unset/unlimited by default) cap concurrent on-demand renewals and new issuances via a shared TTL-guarded slot limiter (`utils/concurrency.lua`), guarding against a burst of sockproc invocations exceeding its accept backlog. Decoupled from `enable_on_demand_renewal` on purpose — turning it on doesn't force a cap along with it.
  - **Account-wide ACME order rate limiter** — concurrency caps bound *simultaneous* ops, not Let's Encrypt's rate *over time* (300 orders/3h per account, shared by issuance and renewal). New `utils/acme_rate_limit.lua`, enforced once at `ssl_provider.issue_cert`, via `max_acme_orders` (unset, no limit) and `acme_order_period` (`10800`, LE's window). On limit: renewal defers without deleting; issuance serves the fallback at `NOTICE`, not `ERR`.
  - **Lock durations were racing dehydrated's own ~60s timeout** — both local `resty.lock`s (`ssl_certificate.lua`, `renewal.lua`) had a 30s `exptime`, short enough to auto-release mid-issuance and let a second concurrent order race the first's ACME authorizations. Raised to `120`, matching the distributed lock's new defaults above.
  - **Stopped deleting the cert on a renewal failure** — unrecoverable via fallback-to-issuance anyway, so deleting just swapped a real, if expired, cert for the fallback. Now logs at `ERR` and retries later; deletion stays reserved for `allow_domain` rejecting the domain outright.
  - Renewal success now logged at `NOTICE` with the new expiry (previously silent on success). Their OCSP-key cache invalidation was dropped — this fork has no such key (OCSP removed in PR #1).

- **DNS check before issuing or renewing** (idea credited to [theerud/lua-resty-auto-ssl](https://github.com/theerud/lua-resty-auto-ssl), own implementation — theirs shipped with a placeholder default and depended on an unrelated multi-provider refactor this fork doesn't have) — a domain whose DNS doesn't point here yet still burned a real ACME attempt (and its quota) only to fail HTTP-01 validation anyway. New `enable_dns_check_before_issuance` (default `false`) resolves the domain via `utils/dns_check.lua` before both a new-issuance and a renewal attempt, skipping (logged at `ERR`) if it fails — baseline check is "resolves at all"; an optional stricter `dns_check_allowed_targets` list can require matching a specific address/CNAME (e.g. this server's own IP), off unless configured since guessing a server's own address isn't safe to do automatically. A renewal DNS failure is treated as transient like the other renewal-failure paths — retried later, not deleted.

  ```lua
  auto_ssl:set("enable_dns_check_before_issuance", true) -- opt in
  auto_ssl:set("dns_check_nameservers", {"8.8.8.8", "1.1.1.1"})
  auto_ssl:set("dns_check_allowed_targets", {"203.0.113.10"}) -- optional, stricter
  ```

- **RedHat vs. Debian `nobody` group name** (also via theerud's fork) — `manual-test/Dockerfile`'s `chown` was hardcoded to `nogroup` (Debian/Ubuntu; RHEL/CentOS uses `nobody`). Not an active bug (the image is Debian-based) but now detected via `getent group nobody` instead of assumed.

- Fixed a real gap while here: `utils/concurrency.lua`/`utils/acme_rate_limit.lua` were never added to the `Makefile`'s `install` target, so a real deployment would be missing them entirely (`ssl_certificate.lua` requires `concurrency` unconditionally at load time — this would fail immediately, not misbehave quietly). Added, along with `dns_check.lua`.

##### New options at a glance

| Option | Default | Purpose |
| --- | --- | --- |
| `issue_cert_lock_wait_time` | `90` (s) | Max wait for an in-progress issuance lock to clear. |
| `issue_cert_lock_poll_interval` | `0.5` (s) | Poll interval while waiting on the above. |
| `issue_cert_lock_exptime` | `120` (s) | How long the issuance lock is held once acquired. |
| `enable_on_demand_renewal` | `false` | Opt-in: check expiry on serve, renew due domains in the background. |
| `renew_trigger_dedup_time` | `600` (s) | Min time between on-demand triggers for the same domain. |
| `renew_max_concurrency` | unset (unlimited) | Opt-in cap on concurrent on-demand renewals. |
| `issue_max_concurrency` | unset (unlimited) | Opt-in cap on concurrent new-certificate issuances. |
| `max_acme_orders` | unset (no limit) | Opt-in account-wide cap on ACME orders (issuance + renewal) per `acme_order_period`. |
| `acme_order_period` | `10800` (3h) | Window `max_acme_orders` is measured over. |
| `enable_dns_check_before_issuance` | `false` | Opt-in: skip issuance/renewal attempts for domains whose DNS doesn't resolve. |
| `dns_check_nameservers` | `{"8.8.8.8", "1.1.1.1"}` | Resolvers used for the check above. |
| `dns_check_allowed_targets` | unset | Optional stricter check: resolved address/CNAME must match an entry in this list. |

PR: [####5](https://github.com/ubmagh/lua-resty-auto-ssl/pull/5)
