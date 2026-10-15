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
# already have this field, run backfill_certs_expiry.sh first.
#
# Uses SCAN (cursor-based, bounded per call via SCAN_COUNT below) rather than
# KEYS, so a large keyspace doesn't block Redis's single command thread for
# the whole migration -- KEYS would stall real cert issuance/renewal traffic
# on a live deployment for however long the full scan takes.
#
# Progress: every PROGRESS_INTERVAL seconds (and once at the end) a progress
# line is printed to stderr. The percentage is estimated from the SCAN
# cursor: SCAN walks the hash table in reverse-binary order, so bit-reversing
# the cursor gives the fraction of buckets already visited. It's an estimate
# (coarse on small keyspaces).
#
# Requires on PATH: a redis-compatible CLI (keydb-cli or redis-cli, see
# REDIS_CLI below), jq.
#
# Usage: configure the deployment-specific settings below to match your
# `redis` storage adapter options, then run:
#   ./scripts/populate_sorted_list.sh
# To use redis-cli instead of the default keydb-cli:
#   REDIS_CLI=redis-cli ./scripts/populate_sorted_list.sh

set -euo pipefail

# --- Configure to match your deployment's `redis` storage adapter options ---
REDIS_CLI="${REDIS_CLI:-keydb-cli}"   # keydb-cli, redis-cli, or a full path; env var overrides
REDIS_HOST="localhost"
REDIS_PORT="6379"
REDIS_AUTH=""         # leave empty if the redis instance has no requirepass
REDIS_DB=""           # leave empty for the default db (0)
REDIS_KEY_PREFIX=""   # must match the `redis` adapter's `prefix` option, if any; leave empty if unset
SCAN_COUNT=500        # keys inspected per SCAN batch -- lower this on a heavily loaded instance
PROGRESS_INTERVAL=5   # seconds between progress lines on stderr

# Must match redis.lua's `_M.certs_zlist`. Like every other key, redis.lua
# runs this through the adapter's key-prefixing too (via prefixed_key()) --
# so REDIS_KEY_PREFIX above applies here as well, computed below.
SORTED_LIST_NAME="certs_zset_store"

if ! command -v "$REDIS_CLI" > /dev/null 2>&1; then
  echo "ERROR: REDIS_CLI='${REDIS_CLI}' not found or not executable" >&2
  exit 1
fi

redis_cmd() {
  local args=(--raw -h "$REDIS_HOST" -p "$REDIS_PORT")
  [ -n "$REDIS_AUTH" ] && args+=(-a "$REDIS_AUTH" --no-auth-warning)
  [ -n "$REDIS_DB" ] && args+=(-n "$REDIS_DB")
  "$REDIS_CLI" "${args[@]}" "$@"
}

# Estimated SCAN progress in permille (0-1000).
# SCAN visits buckets in reverse-binary order, so bit-reversing the cursor
# gives the fraction of the keyspace already covered. Any fixed width at
# least as wide as the hash table gives the same result; 48 bits is plenty.
scan_progress_permille() {
  local c=$1 r=0 i
  for ((i = 0; i < 48; i++)); do
    r=$(( (r << 1) | ((c >> i) & 1) ))
  done
  echo $(( (r * 1000) >> 48 ))
}

report_progress() {
  local p eta="?"
  if [ "$cursor" = "0" ]; then
    p=1000
  else
    p="$(scan_progress_permille "$cursor")"
  fi
  if (( p > 0 && p < 1000 )); then
    eta="$(( SECONDS * (1000 - p) / p ))s"
  elif (( p == 1000 )); then
    eta="0s"
  fi
  printf '[progress] ~%d.%d%% | %ds elapsed | ETA %s | matched %d | migrated %d, skipped %d\n' \
    $((p / 10)) $((p % 10)) "$SECONDS" "$eta" "$matched" "$migrated" "$skipped" >&2
}

if [ -n "$REDIS_KEY_PREFIX" ]; then
  match_pattern="${REDIS_KEY_PREFIX}:*:latest"
  sorted_list_key="${REDIS_KEY_PREFIX}:${SORTED_LIST_NAME}"
else
  match_pattern="*:latest"
  sorted_list_key="$SORTED_LIST_NAME"
fi

echo "Scanning for '${match_pattern}' keys on ${REDIS_HOST}:${REDIS_PORT} via ${REDIS_CLI}..."

migrated=0
skipped=0
matched=0
cursor=0
first_pass=true
last_report=0
SECONDS=0

while [ "$first_pass" = true ] || [ "$cursor" != "0" ]; do
  first_pass=false

  mapfile -t scan_lines < <(redis_cmd SCAN "$cursor" MATCH "$match_pattern" COUNT "$SCAN_COUNT")

  # A failure inside the process substitution doesn't trip `set -e`, so
  # validate the cursor explicitly -- otherwise a connection/auth error would
  # leave a non-numeric cursor that never equals "0" and loop forever.
  cursor="${scan_lines[0]:-}"
  if ! [[ "$cursor" =~ ^[0-9]+$ ]]; then
    echo "ERROR: SCAN failed (got: '${cursor}')" >&2
    exit 1
  fi

  keys=("${scan_lines[@]:1}")
  matched=$((matched + ${#keys[@]}))

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

    redis_cmd ZADD "$sorted_list_key" "$expiry" "$key" > /dev/null
    migrated=$((migrated + 1))
  done

  if (( SECONDS - last_report >= PROGRESS_INTERVAL )) || [ "$cursor" = "0" ]; then
    last_report=$SECONDS
    report_progress
  fi
done

echo "Done in ${SECONDS}s. Matched ${matched}, added/updated ${migrated} key(s) in '${sorted_list_key}', skipped ${skipped} (missing expiry)."
