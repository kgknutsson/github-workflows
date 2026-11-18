#!/usr/bin/env bash
# Delete pr-<number> deployment slots on listed web apps (Running and Stopped).
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

removed_prs=()

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
      echo "Skip non-preview slot name: ${slot}"
      continue
    fi
    if [ -n "${CALLER_PRE_DELETE_SCRIPT:-}" ]; then
      echo "Caller pre-delete for ${webapp}/${slot}..."
      WEBAPP_NAME="$webapp" \
        RESOURCE_GROUP="$RESOURCE_GROUP" \
        SLOT_NAME="$slot" \
        bash "$CALLER_PRE_DELETE_SCRIPT"
    fi
    echo "Deleting ${webapp}/${slot}..."
    az webapp deployment slot delete \
      --name "$webapp" \
      --resource-group "$RESOURCE_GROUP" \
      --slot "$slot"
    pr_num="${slot#pr-}"
    removed_prs+=("$pr_num")
  done
done

if [ -n "${ENTRA_APP_ID:-}" ] && [ "${#removed_prs[@]}" -gt 0 ]; then
  unique_for_entra="$(printf '%s\n' "${removed_prs[@]}" | sort -un | tr '\n' ' ')"
  read_redirects() {
    local value
    value="$(az ad app show --id "$ENTRA_APP_ID" --query "web.redirectUris" -o json)"
    if [ -z "$value" ] || [ "$value" = "null" ]; then
      value="[]"
    fi
    printf '%s' "$value"
  }
  filter_redirects() {
    local source="$1"
    local pr_number
    for pr_number in $unique_for_entra; do
      source="$(printf '%s' "$source" | jq -c --arg num "$pr_number" '[.[] | select((contains("pr-" + $num + ".") or contains("pr-" + $num + "/")) | not)]')"
    done
    printf '%s' "$source"
  }
  current="$(read_redirects)"
  filtered="$(filter_redirects "$current")"
  latest="$(read_redirects)"
  if [ "$(printf '%s' "$current" | jq -c 'sort')" != "$(printf '%s' "$latest" | jq -c 'sort')" ]; then
    echo "Redirect URIs changed. Read the list again."
    current="$latest"
    filtered="$(filter_redirects "$current")"
    latest="$(read_redirects)"
    if [ "$(printf '%s' "$current" | jq -c 'sort')" != "$(printf '%s' "$latest" | jq -c 'sort')" ]; then
      echo "::error::Redirect URIs changed during cleanup. No update was sent."
      exit 1
    fi
  fi
  if [ "$(printf '%s' "$current" | jq -c 'sort')" = "$(printf '%s' "$filtered" | jq -c 'sort')" ]; then
    echo "No matching redirect URIs."
  elif [ "$filtered" = "[]" ]; then
    app_object_id="$(az ad app show --id "$ENTRA_APP_ID" --query id -o tsv)"
    az rest --method PATCH \
      --uri "https://graph.microsoft.com/v1.0/applications/${app_object_id}" \
      --body '{"web":{"redirectUris":[]}}'
  else
    mapfile -t uris < <(printf '%s' "$filtered" | jq -r '.[]')
    az ad app update --id "$ENTRA_APP_ID" --web-redirect-uris "${uris[@]}"
  fi
elif [ -z "${ENTRA_APP_ID:-}" ]; then
  echo "No Entra app id configured. Skip redirect URI cleanup."
fi

stopped_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
unique_prs="$(printf '%s\n' "${removed_prs[@]}" | sort -un | tr '\n' ' ' | xargs || true)"
{
  echo "stopped_pr_numbers=${unique_prs}"
  echo "stopped_at_utc=${stopped_at}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

echo "Deleted preview slots for PR number(s): ${unique_prs:-none}"
