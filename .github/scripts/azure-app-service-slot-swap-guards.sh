#!/usr/bin/env bash
# Shared slot-swap guard helpers (recovery metadata preflight, mutation guard reads).
# Full reconciliation stays in the consumer repo; this script supports scheduled preflight.

set -euo pipefail

RECOVERY_STATE_SETTING="${RECOVERY_STATE_SETTING:-KGK_SLOT_SWAP_RECOVERY_STATE}"
RUN_ID_SETTING="${RUN_ID_SETTING:-KGK_SLOT_SWAP_RUN_ID}"

normalize_setting() {
  case "$1" in
    "" | None | null | NULL) printf '' ;;
    *) printf '%s' "$1" ;;
  esac
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Required environment variable $name is not set." >&2
    exit 1
  fi
}

resource_group() {
  local group="${RESOURCE_GROUP:-${AZURE_RESOURCE_GROUP:-}}"
  if [ -z "$group" ]; then
    echo "::error::Azure resource group is not configured." >&2
    return 1
  fi
  printf '%s' "$group"
}

get_setting() {
  local setting_name="$1"
  local slot="${2:-production}"
  local slot_args=()
  local group
  local value

  require_var WEBAPP_NAME
  case "$slot" in
    production) ;;
    staging) slot_args=(--slot staging) ;;
    *)
      echo "::error::Unsupported App Service slot '$slot'." >&2
      return 1
      ;;
  esac

  group=$(resource_group)
  if ! value=$(az webapp config appsettings list \
    --name "$WEBAPP_NAME" \
    --resource-group "$group" \
    "${slot_args[@]}" \
    --query "[?name=='$setting_name'].value | [0]" \
    -o tsv); then
    echo "::error::Failed to read App Service setting '$setting_name'." >&2
    return 1
  fi
  normalize_setting "$value"
}

http_health_ok() {
  local url="$1"
  local expected="${EXPECTED_HTTP_STATUS:-200}"
  local header_name="${HEALTH_CHECK_HEADER_NAME:-}"
  local header_value="${HEALTH_CHECK_HEADER_VALUE:-}"
  local curl_args=(-s -o /dev/null -w "%{http_code}" --max-time 15 "$url")

  if [ -n "$header_name" ] && [ -n "$header_value" ]; then
    curl_args=(-s -o /dev/null -w "%{http_code}" --max-time 15 -H "${header_name}: ${header_value}" "$url")
  fi

  local status
  status=$(curl "${curl_args[@]}" || true)
  if [ "$status" = "$expected" ]; then
    echo "Health check passed (HTTP $status) at $url"
    return 0
  fi
  echo "Health check returned HTTP $status (expected $expected) at $url"
  return 1
}

production_health_probe() {
  local attempts="${HEALTH_CHECK_ATTEMPTS:-3}"
  local url="${HEALTH_CHECK_URL:-}"

  if [ -z "$url" ]; then
    echo "::error::HEALTH_CHECK_URL is required for scheduled preflight when metadata is idle." >&2
    return 1
  fi

  local i
  for i in $(seq 1 "$attempts"); do
    if http_health_ok "$url"; then
      return 0
    fi
    if [ "$i" -lt "$attempts" ]; then
      sleep 10
    fi
  done
  return 1
}

# Returns 0 when full recovery reconciliation should run, 1 when idle.
cmd_scheduled_preflight() {
  local production_state
  local production_marker
  local staging_marker

  require_var WEBAPP_NAME

  if ! production_state=$(get_setting "$RECOVERY_STATE_SETTING" production); then
    echo "scheduled-preflight-needed=true"
    return 0
  fi
  if ! production_marker=$(get_setting "$RUN_ID_SETTING" production); then
    echo "scheduled-preflight-needed=true"
    return 0
  fi
  if ! staging_marker=$(get_setting "$RUN_ID_SETTING" staging); then
    echo "scheduled-preflight-needed=true"
    return 0
  fi

  case "$production_state" in
    swap-pending | rollback-pending)
      echo "scheduled-preflight-needed=true"
      return 0
      ;;
    "" | healthy) ;;
    *)
      echo "scheduled-preflight-needed=true"
      return 0
      ;;
  esac

  if [ -n "$production_marker" ] || [ -n "$staging_marker" ]; then
    echo "scheduled-preflight-needed=true"
    return 0
  fi

  if production_health_probe; then
    echo "scheduled-preflight-needed=false"
    return 0
  fi

  echo "scheduled-preflight-needed=true"
  return 0
}

usage() {
  echo "Usage: $0 scheduled-preflight" >&2
  exit 1
}

main() {
  case "${1:-}" in
    scheduled-preflight) cmd_scheduled_preflight ;;
    *) usage ;;
  esac
}

main "$@"
