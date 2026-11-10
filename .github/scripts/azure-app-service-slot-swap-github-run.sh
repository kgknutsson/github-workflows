#!/usr/bin/env bash
# GitHub Actions run correlation for KGK slot-swap recovery metadata.
# Source from consumer recovery workflows together with app-specific health/set_healthy helpers.

set -euo pipefail

SLOT_SWAP_DEPLOYMENT_WORKFLOW_PATH="${SLOT_SWAP_DEPLOYMENT_WORKFLOW_PATH:-.github/workflows/deployment.yml}"

slot_swap_run_metadata_is_orphan() {
  [ "${SLOT_SWAP_RUN_METADATA_ORPHAN:-}" = "1" ]
}

load_run_metadata() {
  local marker="$1"
  local marker_slot="$2"
  local auth_header
  local run_json
  local http_code

  unset SLOT_SWAP_RUN_METADATA_ORPHAN
  RUN_ID=""
  EXPECTED_RUN_ATTEMPT=""
  RUN_STATUS=""
  RUN_ATTEMPT=""
  RUN_CONCLUSION=""
  RUN_NAME=""
  RUN_PATH=""

  if [[ ! "$marker" =~ ^run-([0-9]+)-([0-9]+)$ ]]; then
    echo "::error::$marker_slot has an unrecognized slot-swap marker '$marker'. Manual verification is required." >&2
    return 1
  fi

  RUN_ID="${BASH_REMATCH[1]}"
  EXPECTED_RUN_ATTEMPT="${BASH_REMATCH[2]}"

  if [ -z "${API_TOKEN:-}" ]; then
    echo "::error::API_TOKEN is not configured for slot-swap run metadata lookup." >&2
    return 1
  fi
  if [ -z "${GITHUB_REPOSITORY:-}" ]; then
    echo "::error::GITHUB_REPOSITORY is not configured for slot-swap run metadata lookup." >&2
    return 1
  fi

  auth_header="Authorization: Bearer "
  auth_header+="$API_TOKEN"
  set +e
  run_json=$(curl --silent --show-error \
    --connect-timeout 10 \
    --max-time 30 \
    -w "\n__HTTP_CODE__:%{http_code}" \
    -H "$auth_header" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/runs/$RUN_ID/attempts/$EXPECTED_RUN_ATTEMPT")
  local curl_exit=$?
  set -e

  if [ "$curl_exit" -ne 0 ]; then
    echo "::error::Could not query GitHub Actions run $RUN_ID attempt $EXPECTED_RUN_ATTEMPT for $marker_slot marker '$marker'." >&2
    return 1
  fi

  http_code="${run_json##*__HTTP_CODE__:}"
  run_json="${run_json%__HTTP_CODE__:*}"

  if [ "$http_code" = "404" ]; then
    echo "::warning::$marker_slot marker '$marker' references workflow run $RUN_ID attempt $EXPECTED_RUN_ATTEMPT, but GitHub returned HTTP 404 in $GITHUB_REPOSITORY. The run may have been deleted, purged, or never existed in this repository." >&2
    SLOT_SWAP_RUN_METADATA_ORPHAN=1
    return 0
  fi

  if [ "$http_code" != "200" ]; then
    echo "::error::GitHub Actions run lookup for $marker_slot marker '$marker' returned HTTP $http_code. Manual verification is required." >&2
    return 1
  fi

  RUN_STATUS=$(echo "$run_json" | jq -r '.status')
  RUN_ATTEMPT=$(echo "$run_json" | jq -r '.run_attempt')
  RUN_CONCLUSION=$(echo "$run_json" | jq -r '.conclusion')
  RUN_NAME=$(echo "$run_json" | jq -r '.name')
  RUN_PATH=$(echo "$run_json" | jq -r '.path')

  if [ "$RUN_ATTEMPT" != "$EXPECTED_RUN_ATTEMPT" ]; then
    echo "::error::$marker_slot marker '$marker' references run $RUN_ID attempt $EXPECTED_RUN_ATTEMPT, but GitHub reports attempt $RUN_ATTEMPT. Manual verification is required." >&2
    return 1
  fi
  if [ "$RUN_PATH" != "$SLOT_SWAP_DEPLOYMENT_WORKFLOW_PATH" ]; then
    echo "::error::$marker_slot marker references unexpected workflow path '$RUN_PATH' (expected '$SLOT_SWAP_DEPLOYMENT_WORKFLOW_PATH'). Manual verification is required." >&2
    return 1
  fi
  if [ "$RUN_NAME" = "null" ] || [ -z "$RUN_NAME" ]; then
    echo "::error::$marker_slot marker references workflow run $RUN_ID with an empty workflow name. Manual verification is required." >&2
    return 1
  fi

  return 0
}
