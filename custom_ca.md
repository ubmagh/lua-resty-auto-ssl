# Using other ACME certificate authorities

[`ca`](README.md#ca) accepts the directory URL of any ACME v2-compatible certificate authority. Let's Encrypt (below) is the default; two alternatives that have also been tested against this fork follow it.

## Let's Encrypt (default)

No `ca` setting needed for production use. For testing, use the [staging environment](https://letsencrypt.org/docs/staging-environment/) instead of production — this fork's own test suite and `manual-test/` setup both default to it, since production's limits are real and shared across however many test runs you do:

```lua
auto_ssl:set("ca", "https://acme-staging-v02.api.letsencrypt.org/directory") -- staging, for testing
```

### Good to know

- **New orders:** up to 300 per account every 3 hours, refilling at 1 every 36 seconds. This fork's own `acme_order_period` option (see [FORKCHANGES.md](FORKCHANGES.md)) defaults to exactly this 3-hour window, so `max_acme_orders` lines up with Let's Encrypt's real limit if you choose to set it.
- **Certificates per registered domain:** up to 50 every 7 days — this is per registered/eTLD+1 domain (e.g. `example.com`), not per exact hostname, so it's shared across all of that domain's subdomains.
- **Duplicate certificates:** up to 5 per exact same set of domain names every 7 days. The one most likely to bite during manual testing against production, since repeatedly re-issuing for the same test domain burns through it fast — use staging instead.
- Renewals are generally exempt from the new-orders and per-registered-domain limits above (fully exempt if coordinated via ACME Renewal Info/ARI; otherwise still subject to the duplicate-certificate and auth-failure limits).
- Official docs: [letsencrypt.org/docs/rate-limits](https://letsencrypt.org/docs/rate-limits/).

## ZeroSSL

Works with no extra setup beyond setting `ca`:

```lua
auto_ssl:set("ca", "https://acme.zerossl.com/v2/DV90")
```

### Good to know

- ZeroSSL's ACME tier doesn't impose a documented per-domain or total-certificate limit (issuance is described as unlimited on 90-day certs), but it does rate-limit at the *request* level — issuing a certificate covering 3 or more domains over HTTP-01 has been reported to trigger `429` responses from their API. Not something this fork's usage pattern (one domain per cert) runs into directly, but worth knowing if you ever look at multi-domain/SAN certs against ZeroSSL specifically.
- Official docs: [zerossl.com/documentation/acme](https://zerossl.com/documentation/acme).

## Google Public CA

Requires External Account Binding (EAB), which has to be set up manually before `auto_ssl` can issue anything against it — there's no anonymous/auto-registration path like ZeroSSL's.

1. Authorize `pki.goog` to issue for your domain via a CAA DNS record on it — add `0 issue "pki.goog"` as a CAA record for the domain (see Google's [CAA configuration guide](https://developers.google.com/public-key-infrastructure/faq/configure-caa)). Can take 24-48 hours to propagate before issuance will succeed.
2. Generate an EAB key pair (once per Google Cloud project, not per domain): enable the [Public CA API](https://console.cloud.google.com/apis/library/publicca.googleapis.com) on that project, then from Cloud Shell:
   ```sh
   gcloud config set project <your-project-id>
   gcloud publicca external-account-keys create
   ```
   This outputs a `b64MacKey` and a `keyId`.
3. Add that key pair to a [custom dehydrated config file](README.md#advanced-lets-encrypt-configuration), e.g. `/etc/resty-auto-ssl/letsencrypt/conf.d/custom.sh` (check its permissions/ownership match the other files already in that directory):
   ```sh
   EAB_HMAC_KEY="<the b64MacKey value from step 2>"
   EAB_KID="<the keyId value from step 2>"
   ```
4. Set `ca` to Google's directory URL:
   ```lua
   auto_ssl:set("ca", "https://dv.acme-v02.api.pki.goog/directory")
   ```

### Good to know

- **The EAB key pair expires in 7 days if unused.** Generate it, then use it (i.e. actually issue a cert with it) promptly — if it sits for a week first, it's invalidated and you'll need to generate a new one.
- **Quotas are per Google Cloud project, not per EAB key or per server.** If multiple `auto_ssl` instances (or any other ACME client) share the same GCP project, they share the same request quota — creating additional ACME accounts under the same project doesn't get you a separate budget.
- Requests are rate-limited per-minute at the API level; going over returns `429` with a retry-after style backoff, same shape as ZeroSSL's limiting.
- Official docs: [Certificate Manager quotas and limits](https://docs.cloud.google.com/certificate-manager/docs/quotas), [Public CA + ACME client tutorial](https://docs.cloud.google.com/certificate-manager/docs/public-ca-tutorial).
