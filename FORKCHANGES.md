
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

PR: _(link once opened)_


