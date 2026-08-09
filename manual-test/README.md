# Manual testing: redis-sorted-list-renewal

A Docker Compose setup for poking at the `enable_redis_sorted_list_renewal`
feature and its two migration scripts by hand. Not part of the CI matrix
(see the `Dockerfile-test-*` files at the repo root and `spec/` for that).

The app container installs this fork the way a real deployment would --
`luarocks make lua-resty-auto-ssl-git-1.rockspec` against the repo checkout
-- against a real Redis, with `enable_redis_sorted_list_renewal` on and
`allow_domain` wide open. No tunnel/domain is wired up automatically, so
real cert issuance needs the manual tunnel steps below; without it, requests
just get the disposable fallback cert -- which is fine for exercising the
redis/sorted-list mechanics on their own (also below, no domain needed).

## Running it

```sh
cd manual-test && docker compose up --build
```

(or `docker compose -f manual-test/docker-compose.yml up --build` from the
repo root -- either works, Compose resolves `context: ..` relative to the
compose file, not your cwd)

- App: `https://localhost:8443/`, `http://localhost:8080/`
- Redis: exposed on `localhost:6379`, so `../scripts/populate_sorted_list.sh`
  and `../scripts/backfill_certs_expiry.sh` can run straight from your host
  against it. Set `REDIS_AUTH="manual-test-secret"`, `REDIS_DB="1"`,
  `REDIS_KEY_PREFIX="manual-test"` at the top of each first (matching
  `nginx.conf`'s `redis` options) -- `REDIS_HOST="localhost"` is already the
  default.

Rebuild (`docker compose build app`) after changing anything under `lib/` --
it's installed at image-build time, not live-mounted.

## Real cert issuance via a Cloudflare tunnel

```sh
docker compose up --build -d
docker compose exec app bash

# Inside the container -- tunnel port 9080, the only one ACME validation
# needs to reach:
cloudflared tunnel --url http://127.0.0.1:9080 --logfile /tmp/cloudflared.log --loglevel info &
sleep 5
grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cloudflared.log | head -1
export TUNNEL_HOST="paste-the-hostname-here.trycloudflare.com"

# A freshly-announced quick tunnel can take a moment for its DNS to actually
# propagate -- don't move on until this succeeds:
until curl -sf "https://${TUNNEL_HOST}/" -o /dev/null; do sleep 1; done

# Trigger issuance: hit the app's own 9443 directly (the tunnel only carries
# the ACME validation request, nothing routes 9443 through it), forcing the
# tunnel hostname as SNI/Host via --resolve so ssl_certificate.lua's
# SNI-based domain lookup treats this as a request for that real domain:
curl -vk --resolve "${TUNNEL_HOST}:9443:127.0.0.1" "https://${TUNNEL_HOST}:9443/"
# -k skips chain verification since `ca` defaults to LE *staging* here; use
# --cacert /app/spec/certs/letsencrypt_staging_chain.pem instead if you want it.

# Confirm it landed:
docker compose logs -f app   # "issuing new certificate for <TUNNEL_HOST>"
REDIS="redis-cli -h localhost -a manual-test-secret --no-auth-warning -n 1"
$REDIS get "manual-test:${TUNNEL_HOST}:latest"
$REDIS zscore certs_zset_store "manual-test:${TUNNEL_HOST}:latest"
```

`pkill cloudflared` inside the container when done (or just tear the stack
down -- the tunnel doesn't outlive it either way).

## Poking at the feature directly

No domain needed -- seed Redis by hand and watch the renewal job react:

```sh
REDIS="redis-cli -h localhost -a manual-test-secret --no-auth-warning -n 1"

# Seed a fake cert (note the "manual-test:" prefix, matching redis.prefix):
$REDIS set "manual-test:example.test:latest" \
  '{"fullchain_pem":"...","privkey_pem":"...","cert_pem":"...","expiry":'"$(($(date +%s) + 60))"'}'

# Not in the sorted set yet -- only certs written *through* set_cert after
# the option was enabled get added automatically. Backfill it:
$REDIS zscore certs_zset_store "manual-test:example.test:latest"   # (nil)
../scripts/populate_sorted_list.sh
$REDIS zscore certs_zset_store "manual-test:example.test:latest"   # now set

# Trigger a renewal pass on demand (this endpoint is manual-test-only, not
# part of the real library) and watch for it in the logs:
curl http://localhost:8080/manual-renew
docker compose logs -f app   # "checking certificate renewals for example.test"
```

For `backfill_certs_expiry.sh`: seed a value with no `expiry` field but a
real `fullchain_pem`, run it with the default `DRY_RUN=true` to preview,
then `false` to apply and confirm `expiry` got set and the existing TTL (if
any) was preserved.

## Cleaning up

```sh
docker compose down -v   # -v also drops the redis-data volume
```
