
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
- **ngrok v2 → v3** — ngrok removed anonymous tunnels (needs an authtoken now, wired via a repo secret) and, separately, blocked all v2 agents outright for free accounts as of January 2024. Migrated to the v3 agent (new per-OS install method, since the old `bin.equinox.io` per-file download links are gone) and updated the test suite's hostname-parsing regex for the new `*.ngrok-free.app` free-tier domain (previously `*.ngrok.io`).
- **LuaRocks manifest too large for old Lua 5.1** — the LuaRocks bundled in the old pinned `openresty1.13`/`lua51` images predates a fix (LuaRocks 3.12) for the public manifest outgrowing Lua 5.1's 65536-constants-per-chunk bytecode limit. Built LuaRocks 3.13.0 from source against the bundled LuaJIT for those two variants only.

PR: [####2](https://github.com/ubmagh/lua-resty-auto-ssl/pull/2)

