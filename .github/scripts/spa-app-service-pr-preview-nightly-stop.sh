#!/usr/bin/env bash
# Stop Running pr-<number> deployment slots on listed web apps.
set -euo pipefail

: "${RESOURCE_GROUP:?RESOURCE_GROUP is required}"
: "${WEBAPP_NAMES_JSON:?WEBAPP_NAMES_JSON is required}"

mapfile -t webapps < <(python3 - <<'PY' "$WEBAPP_NAMES_JSON"
import json
import sys
data = json.loads(sys.argv[1])
if not isinstance(data, list) or not data:
    raise SystemExit("WEBAPP_NAMES_JSON must be a non-empty JSON array")
for name in data:
    if not isinstance(name, str) or not name:
        raise SystemExit("each web app name must be a non-empty string")
    print(name)
PY
)

stopped_prs=()
stopped_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

for webapp in "${webapps[@]}"; do
  if ! az webapp show --name "$webapp" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "Web app ${webapp} not found; skipping."
    continue
  fi

  mapfile -t slots < <(az webapp deployment slot list \
    --name "$webapp" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?starts_with(name, 'pr-')].name" -o tsv 2>/dev/null || true)

  for slot in "${slots[@]}"; do
    if ! printf '%s' "$slot" | grep -Eq '^pr-[0-9]+$'; then
      continue
    fi
    state="$(az webapp show --name "$webapp" --resource-group "$RESOURCE_GROUP" --slot "$slot" --query state -o tsv 2>/dev/null || echo "")"
    if [ "$state" != "Running" ]; then
      echo "${webapp}/${slot} state=${state:-unknown}; skip stop."
      continue
    fi
    echo "Stopping ${webapp}/${slot}..."
    az webapp stop --name "$webapp" --resource-group "$RESOURCE_GROUP" --slot "$slot"
    pr_num="${slot#pr-}"
    stopped_prs+=("$pr_num")
  done
done

unique_prs="$(printf '%s\n' "${stopped_prs[@]}" | sort -un | tr '\n' ' ' | xargs || true)"
{
  echo "stopped_pr_numbers=${unique_prs}"
  echo "stopped_at_utc=${stopped_at}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

echo "Stopped preview slots for PR number(s): ${unique_prs:-none}"
