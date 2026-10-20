#!/usr/bin/env bash
# Safe Azure App Service staging → production promotion (ARM REST + activity-log correlation).
# Reference behavior: kgknutsson/monorepo PR #1145 (ITCO-1417).

set -euo pipefail

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Required environment variable $name is not set."
    exit 1
  fi
}

normalize_setting() {
  case "$1" in
    '' | None | null | NULL) printf '' ;;
    *) printf '%s' "$1" ;;
  esac
}

monotonic_seconds() {
  python3 -c 'import time; print(int(time.monotonic()))'
}

cmd_autoswap_check() {
  require_var WEBAPP_NAME
  require_var RESOURCE_GROUP
  local staging_slot="${STAGING_SLOT:-staging}"

  local auto_swap
  auto_swap="$(az webapp config show \
    --name "$WEBAPP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --slot "$staging_slot" \
    --query autoSwapSlotName \
    --output tsv)"

  auto_swap="$(normalize_setting "$auto_swap")"
  if [[ -n "$auto_swap" ]]; then
    echo "::error::Azure auto-swap is enabled for ${WEBAPP_NAME}/${staging_slot} (target: ${auto_swap}). Disable auto_swap_slot_name in Terraform before GitHub Actions promotion."
    exit 1
  fi
  echo "Verified auto-swap is disabled on ${WEBAPP_NAME}/${staging_slot}."
}

resolve_staging_health_url() {
  require_var WEBAPP_NAME
  require_var RESOURCE_GROUP
  local staging_slot="${STAGING_SLOT:-staging}"

  if [[ -n "${HEALTH_CHECK_URL:-}" ]]; then
    printf '%s' "$HEALTH_CHECK_URL"
    return 0
  fi

  local staging_host health_path
  staging_host="$(az webapp show \
    --name "$WEBAPP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --slot "$staging_slot" \
    --query defaultHostName \
    --output tsv)"
  staging_host="$(normalize_setting "$staging_host")"
  if [[ -z "$staging_host" ]]; then
    echo "::error::Could not resolve staging hostname for ${WEBAPP_NAME}/${staging_slot}." >&2
    exit 1
  fi

  health_path="${HEALTH_CHECK_PATH:-}"
  if [[ -z "$health_path" ]]; then
    health_path="$(az webapp config show \
      --name "$WEBAPP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --slot "$staging_slot" \
      --query healthCheckPath \
      --output tsv)"
    health_path="$(normalize_setting "$health_path")"
  fi
  if [[ -z "$health_path" ]]; then
    echo "::error::No health check path configured. Set HEALTH_CHECK_PATH or HEALTH_CHECK_URL." >&2
    exit 1
  fi
  [[ "$health_path" == /* ]] || health_path="/${health_path}"
  printf 'https://%s%s' "$staging_host" "$health_path"
}

resolve_production_health_url() {
  require_var WEBAPP_NAME
  require_var RESOURCE_GROUP

  if [[ -n "${PRODUCTION_HEALTH_CHECK_URL:-}" ]]; then
    printf '%s' "$PRODUCTION_HEALTH_CHECK_URL"
    return 0
  fi

  local prod_host health_path
  prod_host="$(az webapp show \
    --name "$WEBAPP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query defaultHostName \
    --output tsv)"
  prod_host="$(normalize_setting "$prod_host")"
  if [[ -z "$prod_host" ]]; then
    echo "::error::Could not resolve production hostname for ${WEBAPP_NAME}." >&2
    exit 1
  fi

  health_path="${PRODUCTION_HEALTH_CHECK_PATH:-${HEALTH_CHECK_PATH:-}}"
  if [[ -z "$health_path" ]]; then
    health_path="$(az webapp config show \
      --name "$WEBAPP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --query healthCheckPath \
      --output tsv)"
    health_path="$(normalize_setting "$health_path")"
  fi
  if [[ -z "$health_path" ]]; then
    echo "::error::No production health check path configured." >&2
    exit 1
  fi
  [[ "$health_path" == /* ]] || health_path="/${health_path}"
  printf 'https://%s%s' "$prod_host" "$health_path"
}

wait_for_http() {
  local url="$1"
  local max_wait="$2"
  local poll_interval="$3"
  local expected="${EXPECTED_HTTP_STATUS:-200}"
  local label="$4"
  local deadline remaining curl_timeout status curl_exit sleep_seconds

  deadline=$(( $(monotonic_seconds) + max_wait ))
  echo "Waiting for ${label}: ${url} (expect HTTP ${expected}, budget ${max_wait}s)"

  while true; do
    remaining=$(( deadline - $(monotonic_seconds) ))
    if [[ "$remaining" -le 0 ]]; then
      break
    fi
    curl_timeout=30
    [[ "$curl_timeout" -le "$remaining" ]] || curl_timeout="$remaining"
    set +e
    status="$(curl -sS -m "$curl_timeout" -o /dev/null -w '%{http_code}' "$url")"
    curl_exit=$?
    set -e
    if [[ "$curl_exit" -eq 0 && "$status" == "$expected" ]]; then
      echo "${label} passed with HTTP ${status}."
      return 0
    fi
    echo "${label} returned HTTP ${status} ($(( max_wait - remaining ))s / ${max_wait}s)."
    remaining=$(( deadline - $(monotonic_seconds) ))
    if [[ "$remaining" -le 0 ]]; then
      break
    fi
    sleep_seconds="$poll_interval"
    [[ "$sleep_seconds" -le "$remaining" ]] || sleep_seconds="$remaining"
    sleep "$sleep_seconds"
  done
  echo "::error::${label} did not return HTTP ${expected} within ${max_wait}s: ${url}"
  exit 1
}

cmd_staging_health() {
  local max_wait="${STAGING_HEALTH_MAX_WAIT_SECONDS:-600}"
  local poll="${POLL_INTERVAL_SECONDS:-15}"
  local url
  url="$(resolve_staging_health_url)"
  wait_for_http "$url" "$max_wait" "$poll" "Staging health check"
}

cmd_production_health() {
  local max_wait="${PRODUCTION_HEALTH_MAX_WAIT_SECONDS:-600}"
  local poll="${POLL_INTERVAL_SECONDS:-15}"
  local url
  url="$(resolve_production_health_url)"
  wait_for_http "$url" "$max_wait" "$poll" "Production health check"
}

cmd_smoke_test() {
  require_var SMOKE_TEST_URL
  local max_wait="${SMOKE_TEST_MAX_WAIT_SECONDS:-600}"
  local poll="${POLL_INTERVAL_SECONDS:-15}"
  wait_for_http "$SMOKE_TEST_URL" "$max_wait" "$poll" "Smoke test"
}

cmd_promote() {
  require_var WEBAPP_NAME
  require_var RESOURCE_GROUP
  local staging_slot="${STAGING_SLOT:-staging}"
  local target_slot="${TARGET_SLOT:-production}"
  local max_wait="${PROMOTION_MAX_WAIT_SECONDS:-900}"
  local poll_interval="${POLL_INTERVAL_SECONDS:-15}"
  local swap_request_timeout="${SWAP_REQUEST_TIMEOUT_SECONDS:-60}"
  if ! [[ "$swap_request_timeout" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::SWAP_REQUEST_TIMEOUT_SECONDS must be a positive integer (got '${swap_request_timeout}')."
    exit 1
  fi

  local site_id access_token
  site_id="$(az webapp show --name "$WEBAPP_NAME" --resource-group "$RESOURCE_GROUP" --query id --output tsv)"
  access_token="$(az account get-access-token --resource https://management.azure.com/ --query accessToken --output tsv)"
  if [[ -z "$site_id" || -z "$access_token" ]]; then
    echo "::error::Could not prepare an authenticated ARM slot-swap request for ${WEBAPP_NAME}."
    exit 1
  fi

  local swap_url swap_body auth_header work_dir
  swap_url="https://management.azure.com${site_id}/slots/${staging_slot}/slotsswap?api-version=2024-11-01"
  swap_body="{\"targetSlot\":\"${target_slot}\",\"preserveVnet\":true}"
  auth_header="Authorization: Bearer ${access_token}"
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT

  local deadline_monotonic=0
  remaining_seconds() {
    local now
    now="$(monotonic_seconds)"
    if [[ "$deadline_monotonic" -le "$now" ]]; then
      echo 0
    else
      echo $((deadline_monotonic - now))
    fi
  }

  local swap_started_at="" swap_lookback_at="" client_request_id="" poll_url=""
  local curl_status=0 http_status=""

  operation_status() {
    if [[ -z "$poll_url" ]]; then
      return 0
    fi
    local poll_status poll_curl_status=0 poll_timeout remaining
    remaining="$(remaining_seconds)"
    [[ "$remaining" -gt 0 ]] || return 0
    poll_timeout=30
    [[ "$poll_timeout" -le "$remaining" ]] || poll_timeout="$remaining"
    : >"$work_dir/poll-body"
    : >"$work_dir/poll-status"
    : >"$work_dir/poll-error"
    curl -sS -L \
      --connect-timeout 10 \
      --max-time "$poll_timeout" \
      -H "$auth_header" \
      -H "Accept: application/json" \
      -o "$work_dir/poll-body" \
      -w '%{http_code}' \
      "$poll_url" >"$work_dir/poll-status" 2>"$work_dir/poll-error" || poll_curl_status=$?
    poll_status="$(cat "$work_dir/poll-status" 2>/dev/null || true)"
    if [[ "$poll_curl_status" -ne 0 || "$poll_status" != "200" ]]; then
      return 0
    fi
    python3 - "$work_dir/poll-body" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)

if not isinstance(payload, dict):
    raise SystemExit(0)

status = payload.get("status")
if not status and isinstance(payload.get("properties"), dict):
    status = payload["properties"].get("status")
if not status:
    status = payload.get("state")
if status:
    print(str(status).lower())
PY
  }

  activity_status() {
    local activity_file="$work_dir/activity.json"
    local remaining
    remaining="$(remaining_seconds)"
    [[ "$remaining" -gt 0 ]] || return 0
    : >"$activity_file"
    if ! timeout --signal=TERM "${remaining}s" az monitor activity-log list \
      --resource-group "$RESOURCE_GROUP" \
      --start-time "$swap_lookback_at" \
      --max-events 200 \
      --output json >"$activity_file" 2>"$work_dir/activity-error"; then
      return 0
    fi
    python3 - "$activity_file" "$client_request_id" "$swap_started_at" <<'PY'
import json
import sys
from datetime import datetime, timezone

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        events = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)

if not isinstance(events, list):
    raise SystemExit(0)

terminal_statuses = {"succeeded", "failed", "canceled", "cancelled"}
expected_client_request_id = sys.argv[2]
request_started_at = sys.argv[3]

def timestamp(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return datetime.min.replace(tzinfo=timezone.utc)

def event_status(event):
    status = event.get("status") or {}
    return str(status.get("value") or status.get("localizedValue") or "").lower()

def correlation_id(event):
    return event.get("correlationId") or event.get("operationId") or ""

swap_events = []
for event in events:
    operation = event.get("operationName") or {}
    operation_name = str(operation.get("value") or "").lower()
    if "slotsswap" not in operation_name.replace("/", ""):
        continue
    event["normalized_timestamp"] = timestamp(event.get("eventTimestamp"))
    event["normalized_status"] = event_status(event)
    swap_events.append(event)

if not swap_events:
    raise SystemExit(0)

matching_correlations = {
    correlation_id(event)
    for event in swap_events
    if (event.get("httpRequest") or {}).get("clientRequestId") == expected_client_request_id
    and correlation_id(event)
}

if matching_correlations:
    candidates = [
        event
        for event in swap_events
        if correlation_id(event) in matching_correlations
        and event["normalized_status"] in terminal_statuses
        and event["normalized_timestamp"] >= timestamp(request_started_at)
    ]
    if candidates:
        print(max(candidates, key=lambda event: event["normalized_timestamp"])["normalized_status"])
    raise SystemExit(0)
PY
  }

  wait_for_swap() {
    local current_status="" current_activity_status=""
    while [[ "$(remaining_seconds)" -gt 0 ]]; do
      current_status="$(operation_status)"

      case "$current_status" in
        succeeded | success | completed)
          echo "Azure confirmed the slot swap completed."
          return 0
          ;;
        failed | canceled | cancelled)
          echo "::error::Azure reported that the slot swap failed for ${WEBAPP_NAME}."
          cat "$work_dir/poll-body" 2>/dev/null || true
          return 1
          ;;
      esac

      current_activity_status="$(activity_status)"
      case "$current_activity_status" in
        succeeded | success | completed)
          echo "Azure activity logs confirmed the slot swap completed."
          return 0
          ;;
        failed | canceled | cancelled)
          echo "::error::Azure activity logs reported that the slot swap failed for ${WEBAPP_NAME}."
          return 1
          ;;
      esac

      local remaining sleep_seconds
      remaining="$(remaining_seconds)"
      [[ "$remaining" -gt 0 ]] || break
      sleep_seconds="$poll_interval"
      [[ "$sleep_seconds" -le "$remaining" ]] || sleep_seconds="$remaining"
      echo "Waiting for Azure to complete the slot swap ($((max_wait - remaining))s / ${max_wait}s)..."
      sleep "$sleep_seconds"
    done

    if [[ -s "$work_dir/activity-error" ]]; then
      echo "::warning::Azure activity-log reconciliation queries failed."
      sed -n '1,5p' "$work_dir/activity-error"
    fi
    echo "::error::The slot-swap request for ${WEBAPP_NAME} has no confirmed terminal result within the ${max_wait}s deadline. No retry was attempted because Azure may have completed the swap."
    return 2
  }

  submit_swap_request() {
    local request_timeout remaining
    curl_status=0
    swap_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    swap_lookback_at="$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
    client_request_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    request_timeout="$swap_request_timeout"
    remaining="$(remaining_seconds)"
    if [[ "$remaining" -le 0 ]]; then
      curl_status=124
      return 0
    fi
    [[ "$request_timeout" -le "$remaining" ]] || request_timeout="$remaining"

    : >"$work_dir/response-headers"
    : >"$work_dir/response-body"
    : >"$work_dir/response-status"
    : >"$work_dir/response-error"
    curl -sS \
      --connect-timeout 15 \
      --max-time "$request_timeout" \
      -X POST \
      -H "$auth_header" \
      -H "x-ms-client-request-id: ${client_request_id}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --data "$swap_body" \
      -D "$work_dir/response-headers" \
      -o "$work_dir/response-body" \
      -w '%{http_code}' \
      "$swap_url" >"$work_dir/response-status" 2>"$work_dir/response-error" || curl_status=$?

    http_status="$(cat "$work_dir/response-status" 2>/dev/null || true)"
    [[ -n "$http_status" ]] || http_status=000
    poll_url="$(awk -F': ' 'tolower($1) == "azure-asyncoperation" { gsub("\r", "", $2); print $2 }' "$work_dir/response-headers" | tail -n 1)"
    if [[ -z "$poll_url" ]]; then
      poll_url="$(awk -F': ' 'tolower($1) == "location" { gsub("\r", "", $2); print $2 }' "$work_dir/response-headers" | tail -n 1)"
    fi
    if [[ "$poll_url" == /* ]]; then
      poll_url="https://management.azure.com${poll_url}"
    fi
  }

  deadline_monotonic=$(( $(monotonic_seconds) + max_wait ))
  echo "Submitting non-blocking ARM slot swap for ${WEBAPP_NAME} ${staging_slot} -> ${target_slot}..."
  submit_swap_request

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "client-request-id=${client_request_id}"
      echo "swap-started-at=${swap_started_at}"
    } >>"$GITHUB_OUTPUT"
  fi

  if [[ "$curl_status" -ne 0 || "$http_status" == "000" ]]; then
    echo "The ARM request did not return cleanly (curl exit ${curl_status}). Checking Azure before deciding whether the swap completed..."
    set +e
    wait_for_swap
    WAIT_STATUS=$?
    set -e
    exit "$WAIT_STATUS"
  fi

  if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    if [[ "$http_status" == "200" && -z "$poll_url" ]]; then
      echo "Azure accepted and completed the slot swap."
      exit 0
    fi
    set +e
    wait_for_swap
    WAIT_STATUS=$?
    set -e
    exit "$WAIT_STATUS"
  fi

  if [[ "$http_status" == "409" ]] && grep -Eqi 'another operation is in progress|04026' "$work_dir/response-body"; then
    echo "::error::Azure reports another slot operation is in progress (HTTP 409 / 04026). The workflow will not retry or infer success because that could reverse an external or earlier swap. Reconcile the active operation before rerunning."
    cat "$work_dir/response-body" 2>/dev/null || true
    cat "$work_dir/response-error" 2>/dev/null || true
    exit 1
  fi

  echo "::error::Slot swap request failed for ${WEBAPP_NAME} with HTTP ${http_status}."
  cat "$work_dir/response-body" 2>/dev/null || true
  cat "$work_dir/response-error" 2>/dev/null || true
  exit 1
}

usage() {
  echo "Usage: $0 {autoswap-check|staging-health|promote|production-health|smoke-test}" >&2
  exit 1
}

main() {
  [[ $# -eq 1 ]] || usage
  case "$1" in
    autoswap-check) cmd_autoswap_check ;;
    staging-health) cmd_staging_health ;;
    promote) cmd_promote ;;
    production-health) cmd_production_health ;;
    smoke-test) cmd_smoke_test ;;
    *) usage ;;
  esac
}

main "$@"
