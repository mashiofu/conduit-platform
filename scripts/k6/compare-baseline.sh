#!/usr/bin/env bash
# The actual "detect a performance regression" gate: compares a k6 run's
# summary.json against that environment's stored baseline. Fails (exit 1)
# if p95 latency grew by more than the allowed margin, or the error rate
# exceeds its own hard cap.
#
# Usage: compare-baseline.sh <dev|staging|prod> <path-to-summary.json>
set -euo pipefail

ENV="${1:?usage: $0 <dev|staging|prod> <summary.json>}"
SUMMARY_FILE="${2:?usage: $0 <dev|staging|prod> <summary.json>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE_FILE="$SCRIPT_DIR/baselines/${ENV}.json"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

if [ ! -f "$BASELINE_FILE" ]; then
  # First-run fallback only - this write is local to whatever checkout is
  # running (e.g. a CI runner's throwaway filesystem) and is NOT
  # committed back to the repo. Baselines are meant to ratchet forward
  # deliberately, by a human committing an updated baselines/<env>.json
  # when performance genuinely and intentionally improves - not silently,
  # from every run that happens to have no baseline to compare against.
  echo "No baseline yet for $ENV at $BASELINE_FILE - treating this run as the baseline (not persisted; commit baselines/${ENV}.json yourself to make it stick)."
  mkdir -p "$(dirname "$BASELINE_FILE")"
  cp "$SUMMARY_FILE" "$BASELINE_FILE"
  exit 0
fi

BASELINE_P95="$(jq -r '.p95_ms' "$BASELINE_FILE")"
BASELINE_ERROR_RATE="$(jq -r '.error_rate' "$BASELINE_FILE")"
ACTUAL_P95="$(jq -r '.p95_ms' "$SUMMARY_FILE")"
ACTUAL_ERROR_RATE="$(jq -r '.error_rate' "$SUMMARY_FILE")"

# 20% p95 headroom: tight enough to catch a real regression, loose enough
# not to flap on ordinary network/runner noise between runs.
MAX_P95="$(awk -v b="$BASELINE_P95" 'BEGIN { printf "%.2f", b * 1.2 }')"
MAX_ERROR_RATE="0.02"

echo "baseline: p95=${BASELINE_P95}ms error_rate=${BASELINE_ERROR_RATE}"
echo "actual:   p95=${ACTUAL_P95}ms error_rate=${ACTUAL_ERROR_RATE}"
echo "allowed:  p95<=${MAX_P95}ms error_rate<=${MAX_ERROR_RATE}"

FAILED=0

if awk -v a="$ACTUAL_P95" -v m="$MAX_P95" 'BEGIN { exit !(a > m) }'; then
  echo "REGRESSION: p95 latency ${ACTUAL_P95}ms exceeds allowed ${MAX_P95}ms (baseline ${BASELINE_P95}ms)" >&2
  FAILED=1
fi

if awk -v a="$ACTUAL_ERROR_RATE" -v m="$MAX_ERROR_RATE" 'BEGIN { exit !(a > m) }'; then
  echo "REGRESSION: error rate ${ACTUAL_ERROR_RATE} exceeds allowed ${MAX_ERROR_RATE}" >&2
  FAILED=1
fi

if [ "$FAILED" -eq 0 ]; then
  echo "OK: within baseline"
fi

exit "$FAILED"
