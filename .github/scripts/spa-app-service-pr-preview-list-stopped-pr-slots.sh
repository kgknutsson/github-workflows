#!/usr/bin/env bash
# List pr-<number> slot names in Stopped state for one web app.
set -euo pipefail

: "${WEBAPP_NAME:?WEBAPP_NAME is required}"
: "${RESOURCE_GROUP:?RESOURCE_GROUP is required}"

if ! az webapp show --name "$WEBAPP_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "pr_numbers=" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

slots_tsv="$(az webapp deployment slot list \
  --name "$WEBAPP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?starts_with(name, 'pr-')].name" -o tsv)"

mapfile -t slots <<< "$slots_tsv"
if [ "${#slots[@]}" -eq 1 ] && [ -z "${slots[0]:-}" ]; then
  slots=()
fi

pr_numbers=()
for slot in "${slots[@]}"; do
  if ! printf '%s' "$slot" | grep -Eq '^pr-[0-9]+$'; then
    continue
  fi
  state="$(az webapp show --name "$WEBAPP_NAME" --resource-group "$RESOURCE_GROUP" --slot "$slot" --query state -o tsv)"
  if [ "$state" = "Stopped" ]; then
    pr_numbers+=("${slot#pr-}")
  fi
done

unique="$(printf '%s\n' "${pr_numbers[@]}" | sort -un | tr '\n' ' ' | xargs || true)"
echo "pr_numbers=${unique}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "Stopped pr-* slots on ${WEBAPP_NAME}: ${unique:-none}"
