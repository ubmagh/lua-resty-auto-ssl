#!/bin/bash
#
# backfill_certs_expiry.sh
#
# Prerequisite for populate_sorted_list.sh (run this one first). Certs
# written by a sufficiently old version of this library may not have a
# numeric `expiry` field recorded in their stored JSON value at all (see the
# equivalent legacy-backfill handling in jobs/renewal.lua for the same gap on
# the non-sorted-list path) -- populate_sorted_list.sh has nothing to score
# those with, so they'd silently never enter the sorted set. This script
# finds exactly those and backfills `expiry` by extracting the certificate's
# real notAfter date straight from its own stored `fullchain_pem`, the same
# source of truth dehydrated itself would use.
#
# What it does: SCANs (not KEYS, for the same reason as everywhere else in
# this fork -- see populate_sorted_list.sh) for every existing `*:latest`
# cert key. Any value that already has a numeric `expiry` is left untouched.
# For one that doesn't, it extracts `fullchain_pem` from the JSON, runs
# `openssl x509 -enddate` on it, converts that to a unix timestamp, and
# rewrites the same key with `expiry` set -- preserving whatever TTL (if
# any) the key already had, via a single atomic `SET ... EX`, rather than a
# separate SET + EXPIRE that could race a concurrent read.
#
# Progress: every PROGRESS_INTERVAL seconds (and once at the end) a progress
# line is printed to stderr. The percentage is estimated from the SCAN
# cursor: SCAN walks the hash table in reverse-binary order, so bit-reversing
# the cursor gives the fraction of buckets already visited. It's an estimate
# (coarse on small keyspaces), and the ETA assumes a roughly even mix of
# keys that need backfilling vs. keys that are already fine.
#
# Safe to re-run: a key that already has `expiry` is always left alone, so a
# second run is a no-op over anything the first run already fixed.
#
# DRY_RUN defaults to true below -- it logs exactly what it would change
# without writing anything back. Review that output, then set it to false
# for the real run.
#
# Requires on PATH: a redis-compatible CLI (keydb-cli or redis-cli, see
# REDIS_CLI below), jq, openssl, date (GNU date -- specifically
# `date -d`, to parse openssl's `notAfter=...` output; this targets the same
# Linux deployment environment this library itself targets, not necessarily
# BSD/macOS `date`), sed.
#
# Usage: configure the deployment-specific settings below to match your
# `redis` storage adapter options, then run:
#   ./backfill.sh
# To keep the per-key log separate from the progress lines:
#   ./backfill.sh > backfill.log

set -euo pipefail

# --- Configure to match your deployment's `redis` storage adapter options ---
# CLI client: keydb-cli, redis-cli, or a full path. Leave empty to auto-detect
# (keydb-cli first, then redis-cli). Can also be set from the environment:
#   REDIS_CLI=redis-cli ./backfill.sh
REDIS_CLI="${REDIS_CLI:-keydb-cli}"
REDIS_HOST="localhost"
REDIS_PORT="6379"
REDIS_AUTH=""         # leave empty if the redis instance has no requirepass
REDIS_DB=""           # leave empty for the default db (0)
REDIS_KEY_PREFIX=""   # must match the `redis` adapter's `prefix` option, if any; leave empty if unset
SCAN_COUNT=500        # keys inspected per SCAN batch -- lower this on a heavily loaded instance
PROGRESS_INTERVAL=15  # seconds between progress lines on stderr

DRY_RUN=true          # set to false once you've reviewed a dry run's output

redis_cmd() {
  local args=(--raw -h "$REDIS_HOST" -p "$REDIS_PORT")
  [ -n "$REDIS_AUTH" ] && args+=(-a "$REDIS_AUTH" --no-auth-warning)
  [ -n "$REDIS_DB" ] && args+=(-n "$REDIS_DB")
  "$REDIS_CLI" "${args[@]}" "$@"
}

# Resolve the CLI client: explicit setting wins, otherwise auto-detect.
if [ -z "$REDIS_CLI" ]; then
  for candidate in keydb-cli redis-cli; do
    if command -v "$candidate" > /dev/null 2>&1; then
      REDIS_CLI="$candidate"
      break
    fi
  done
fi
if [ -z "$REDIS_CLI" ]; then
  echo "ERROR: neither keydb-cli nor redis-cli found on PATH; set REDIS_CLI" >&2
  exit 1
fi
if ! command -v "$REDIS_CLI" > /dev/null 2>&1; then
  echo "ERROR: REDIS_CLI='${REDIS_CLI}' not found or not executable" >&2
  exit 1
fi

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
  printf '[progress] ~%d.%d%% | %ds elapsed | ETA %s | matched %d | backfilled %d, ok %d, skipped %d\n' \
    $((p / 10)) $((p % 10)) "$SECONDS" "$eta" "$matched" "$backfilled" "$already_ok" "$skipped" >&2
}

if [ -n "$REDIS_KEY_PREFIX" ]; then
  match_pattern="${REDIS_KEY_PREFIX}:*:latest"
else
  match_pattern="*:latest"
fi

echo "Scanning for '${match_pattern}' keys on ${REDIS_HOST}:${REDIS_PORT} via ${REDIS_CLI}... (DRY_RUN=${DRY_RUN})"

backfilled=0
skipped=0
already_ok=0
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
      # Key expired/was deleted between the SCAN and this GET -- harmless.
      continue
    fi

    existing_expiry="$(printf '%s' "$value" | jq -r '.expiry // empty' 2>/dev/null || true)"
    if [ -n "$existing_expiry" ] && [ "$existing_expiry" != "null" ]; then
      already_ok=$((already_ok + 1))
      continue
    fi

    echo "No existing expiry found for '${key}', attempting to derive from fullchain_pem..."

    fullchain_pem="$(printf '%s' "$value" | jq -r '.fullchain_pem // empty' 2>/dev/null || true)"
    if [ -z "$fullchain_pem" ]; then
      echo "WARNING: skipping '${key}' -- no expiry and no fullchain_pem to derive one from" >&2
      skipped=$((skipped + 1))
      continue
    fi

    pem_tmpfile="$(mktemp)"
    printf '%s\n' "$fullchain_pem" > "$pem_tmpfile"

    enddate="$(openssl x509 -enddate -noout -in "$pem_tmpfile" 2>/dev/null | sed -n 's/^notAfter=//p' || true)"
    rm -f "$pem_tmpfile"

    if [ -z "$enddate" ]; then
      echo "WARNING: skipping '${key}' -- could not read an end date from its fullchain_pem" >&2
      skipped=$((skipped + 1))
      continue
    fi

    epoch="$(date -d "$enddate" +%s 2>/dev/null || true)"
    if [ -z "$epoch" ]; then
      echo "WARNING: skipping '${key}' -- could not parse '${enddate}' into a timestamp" >&2
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$DRY_RUN" = true ]; then
      echo "DRY RUN: would set expiry=${epoch} on '${key}' (notAfter: ${enddate})"
      backfilled=$((backfilled + 1))
      continue
    fi

    new_value="$(printf '%s' "$value" | jq -c --argjson exp "$epoch" '.expiry = $exp')"

    ttl="$(redis_cmd TTL "$key")"
    if [ "$ttl" -gt 0 ]; then
      redis_cmd SET "$key" "$new_value" EX "$ttl" > /dev/null
    elif [ "$ttl" = "-1" ]; then
      redis_cmd SET "$key" "$new_value" > /dev/null
    else
      # -2 (or anything else unexpected): key vanished since the GET above.
      echo "WARNING: skipping write for '${key}' -- key no longer exists" >&2
      skipped=$((skipped + 1))
      continue
    fi

    backfilled=$((backfilled + 1))
  done

  if (( SECONDS - last_report >= PROGRESS_INTERVAL )) || [ "$cursor" = "0" ]; then
    last_report=$SECONDS
    report_progress
  fi
done

echo "Done in ${SECONDS}s. Matched ${matched}, backfilled ${backfilled}, already had expiry ${already_ok}, skipped ${skipped}."
if [ "$DRY_RUN" = true ]; then
  echo "This was a dry run -- nothing was written. Set DRY_RUN=false at the top of this script to apply."
fi
