#!/usr/bin/env bash
# Fail when the App Service plan memory metric is above the caller threshold.
set -euo pipefail

: "${PLAN_NAME:?PLAN_NAME is required}"
: "${PLAN_RESOURCE_GROUP:?PLAN_RESOURCE_GROUP is required}"
: "${THRESHOLD:?THRESHOLD is required}"

if ! printf '%s' "$THRESHOLD" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
  echo "::error::THRESHOLD must be a number."
  exit 1
fi

if awk -v limit="$THRESHOLD" 'BEGIN { exit (limit + 0 < 0 || limit + 0 > 100) ? 0 : 1 }'; then
  echo "::error::THRESHOLD must be between 0 and 100."
  exit 1
fi

plan_id="$(az appservice plan show --name "$PLAN_NAME" --resource-group "$PLAN_RESOURCE_GROUP" --query id -o tsv)"
if [ -z "$plan_id" ]; then
  echo "::error::App Service plan ${PLAN_NAME} was not found in ${PLAN_RESOURCE_GROUP}."
  exit 1
fi

end="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
start="$(date -u -d '20 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")"

metrics_json="$(mktemp)"
trap 'rm -f "$metrics_json"' EXIT
az monitor metrics list \
  --resource "$plan_id" \
  --metric MemoryPercentage \
  --aggregation Average \
  --interval PT15M \
  --start-time "$start" \
  --end-time "$end" \
  -o json >"$metrics_json"

avg="$(python3 - "$metrics_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

points = (
    payload.get("value", [{}])[0]
    .get("timeseries", [{}])[0]
    .get("data", [])
)
values = [point["average"] for point in points if point.get("average") is not None]
if not values:
    print("")
    raise SystemExit(0)
print(f"{sum(values) / len(values):.4f}")
PY
)"

if [ -z "$avg" ]; then
  echo "::warning::Plan memory metric returned no samples; skipping memory gate."
  exit 0
fi

echo "Plan ${PLAN_NAME} memory (15m avg): ${avg}% (threshold ${THRESHOLD}%)."

if awk -v memory="$avg" -v limit="$THRESHOLD" 'BEGIN { exit (memory + 0 > limit + 0) ? 0 : 1 }'; then
  echo "::error::Shared App Service plan memory is ${avg}% (limit ${THRESHOLD}%)."
  echo "::error::Close old pull requests, wait for nightly preview shutoff, or stop other pr-* slots on this plan."
  exit 1
fi
