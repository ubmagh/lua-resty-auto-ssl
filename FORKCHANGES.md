
### Fork changes

#### Remove OCSP stapling support

OCSP stapling has been dropped (`ocsp_stapling_error_level` option, `get_ocsp_response`/`set_ocsp_stapling` in `ssl_certificate.lua`, and the `ngx.ocsp` dependency). Most CAs have deprecated or fully shut down OCSP in favor of CRLs, so this code path was querying infrastructure that increasingly no longer exists:

- CA/Browser Forum made OCSP optional for CAs (and CRLs mandatory) starting March 2024.
- Let's Encrypt announced its OCSP shutdown in December 2024 and completed it on August 6, 2025 — its OCSP responders are offline and certificates no longer include OCSP URLs.

References:
- https://letsencrypt.org/2024/12/05/ending-ocsp
- https://letsencrypt.org/2025/08/06/ocsp-service-has-reached-end-of-life
- https://community.letsencrypt.org/t/ending-ocsp-support-in-2025/229786

PR: [####1](https://github.com/ubmagh/lua-resty-auto-ssl/pull/1)

#### CI fixes

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

PR: [####2](https://github.com/ubmagh/lua-resty-auto-ssl/pull/2)

