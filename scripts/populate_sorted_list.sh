#!/bin/bash
#
# populate_sorted_list.sh
#
# One-time (but safely re-runnable) migration script for the redis storage
# adapter's `enable_redis_sorted_list_renewal` feature (see redis.lua and
# FORKCHANGES.md). Existing deployments upgrading to that feature have all
# of their certs scattered as plain `<domain>:latest` keys with no
# corresponding entry in the sorted set the renewal job reads from once the
# feature is turned on -- without running this first, none of those
# already-existing certs would ever be picked up for automatic renewal again.
#
# What it does: SCANs (not KEYS -- see below) for every existing `*:latest`
# cert key, reads each one's `expiry` field out of its stored JSON value, and
# ZADDs it into the sorted set with that expiry as its score -- exactly
# mirroring what redis.lua's set() now does automatically for every *newly*
# written cert. Safe to re-run any number of times: ZADD on a member that's
# already in the set just updates its score, so this never creates
# duplicates or otherwise corrupts state on a second run.
#
# PRECONDITION: every `<domain>:latest` value must carry a numeric `expiry`
# field. Certs written by a sufficiently old version of this library may not
# have one (see the backfill logic in jobs/renewal.lua for the equivalent
# gap on the non-sorted-list path). This script does NOT attempt to recover
# a missing expiry itself -- it only logs a warning and skips any cert key
# it finds without one. If you're not sure all of your existing certs
# already have this field, run the expiry-backfill script (separate, not
# yet written) first.
#
# Uses SCAN (cursor-based, bounded per call via SCAN_COUNT below) rather than
# KEYS, so a large keyspace doesn't block Redis's single command thread for
# the whole migration -- KEYS would stall real cert issuance/renewal traffic
# on a live deployment for however long the full scan takes.
#
# Requires on PATH: redis-cli, jq, grep, awk, sed. Of these, only jq isn't
# already a hard runtime dependency of this library elsewhere.
#
# Usage: configure the deployment-specific settings below to match your
# `redis` storage adapter options, then run:
#   ./scripts/populate_sorted_list.sh

set -euo pipefail

# --- Configure to match your deployment's `redis` storage adapter options ---
REDIS_HOST="localhost"
REDIS_PORT="6379"
REDIS_AUTH=""         # leave empty if the redis instance has no requirepass
REDIS_DB=""           # leave empty for the default db (0)
REDIS_KEY_PREFIX=""   # must match the `redis` adapter's `prefix` option, if any; leave empty if unset
SCAN_COUNT=500        # keys inspected per SCAN batch -- lower this on a heavily loaded instance

# Must match redis.lua's `_M.certs_zlist`. Note this is intentionally used
# as-is, never run through the adapter's key-prefixing -- redis.lua doesn't
# prefix it either, so this has to match that behavior exactly, not the
# per-cert key prefixing above.
SORTED_LIST_NAME="certs_zset_store"

redis_cmd() {
  local args=(--raw -h "$REDIS_HOST" -p "$REDIS_PORT")
  [ -n "$REDIS_AUTH" ] && args+=(-a "$REDIS_AUTH" --no-auth-warning)
  [ -n "$REDIS_DB" ] && args+=(-n "$REDIS_DB")
  redis-cli "${args[@]}" "$@"
}

if [ -n "$REDIS_KEY_PREFIX" ]; then
  match_pattern="${REDIS_KEY_PREFIX}:*:latest"
else
  match_pattern="*:latest"
fi

echo "Scanning for '${match_pattern}' keys on ${REDIS_HOST}:${REDIS_PORT}..."

migrated=0
skipped=0
cursor=0
first_pass=true

while [ "$first_pass" = true ] || [ "$cursor" != "0" ]; do
  first_pass=false

  mapfile -t scan_lines < <(redis_cmd SCAN "$cursor" MATCH "$match_pattern" COUNT "$SCAN_COUNT")
  cursor="${scan_lines[0]}"
  keys=("${scan_lines[@]:1}")

  for key in "${keys[@]}"; do
    [ -z "$key" ] && continue

    value="$(redis_cmd GET "$key")"
    if [ -z "$value" ]; then
      # Key expired/was deleted between the SCAN and this GET -- harmless,
      # just nothing left to migrate for it.
      continue
    fi

    expiry="$(printf '%s' "$value" | jq -r '.expiry // empty' 2>/dev/null || true)"
    if [ -z "$expiry" ] || [ "$expiry" = "null" ]; then
      echo "WARNING: skipping '${key}' -- no numeric expiry field found in its stored value" >&2
      skipped=$((skipped + 1))
      continue
    fi

    redis_cmd ZADD "$SORTED_LIST_NAME" "$expiry" "$key" > /dev/null
    migrated=$((migrated + 1))
  done
done

echo "Done. Added/updated ${migrated} key(s) in '${SORTED_LIST_NAME}', skipped ${skipped} (missing expiry)."
