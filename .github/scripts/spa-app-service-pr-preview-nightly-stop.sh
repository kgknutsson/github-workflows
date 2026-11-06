#!/usr/bin/env bash
# Stop Running pr-<number> deployment slots on listed web apps.
set -euo pipefail

: "${RESOURCE_GROUP:?RESOURCE_GROUP is required}"
: "${WEBAPP_NAMES_JSON:?WEBAPP_NAMES_JSON is required}"

webapps_raw="$(python3 - "$WEBAPP_NAMES_JSON" <<'PY'
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
)"

mapfile -t webapps <<< "$webapps_raw"

stopped_prs=()

for webapp in "${webapps[@]}"; do
  if ! az webapp show --name "$webapp" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "Web app ${webapp} not found; skipping."
    continue
  fi

  slots_tsv="$(az webapp deployment slot list \
    --name "$webapp" \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?starts_with(name, 'pr-')].name" -o tsv)"

  mapfile -t slots <<< "$slots_tsv"
  if [ "${#slots[@]}" -eq 1 ] && [ -z "${slots[0]:-}" ]; then
    slots=()
  fi

  for slot in "${slots[@]}"; do
    if ! printf '%s' "$slot" | grep -Eq '^pr-[0-9]+$'; then
      continue
    fi
    state="$(az webapp show --name "$webapp" --resource-group "$RESOURCE_GROUP" --slot "$slot" --query state -o tsv)"
    if [ "$state" != "Running" ]; then
      echo "${webapp}/${slot} state=${state}; skip stop."
      continue
    fi
    echo "Stopping ${webapp}/${slot}..."
    az webapp stop --name "$webapp" --resource-group "$RESOURCE_GROUP" --slot "$slot"
    pr_num="${slot#pr-}"
    stopped_prs+=("$pr_num")
  done
done

stopped_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
unique_prs="$(printf '%s\n' "${stopped_prs[@]}" | sort -un | tr '\n' ' ' | xargs || true)"
{
  echo "stopped_pr_numbers=${unique_prs}"
  echo "stopped_at_utc=${stopped_at}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

echo "Stopped preview slots for PR number(s): ${unique_prs:-none}"
