
### Fork changes

#### Remove OCSP stapling support

OCSP stapling has been dropped (`ocsp_stapling_error_level` option, `get_ocsp_response`/`set_ocsp_stapling` in `ssl_certificate.lua`, and the `ngx.ocsp` dependency). Most CAs have deprecated or fully shut down OCSP in favor of CRLs, so this code path was querying infrastructure that increasingly no longer exists:

- CA/Browser Forum made OCSP optional for CAs (and CRLs mandatory) starting March 2024.
- Let's Encrypt announced its OCSP shutdown in December 2024 and completed it on August 6, 2025 — its OCSP responders are offline and certificates no longer include OCSP URLs.

References:
- https://letsencrypt.org/2024/12/05/ending-ocsp
- https://letsencrypt.org/2025/08/06/ocsp-service-has-reached-end-of-life
- https://community.letsencrypt.org/t/ending-ocsp-support-in-2025/229786

PR: _(link once opened)_


