#!/usr/bin/env bash
# Wait until the App Service SCM (Kudu) endpoint responds with something other than HTTP 503.
set -euo pipefail

WEBAPP_NAME="${WEBAPP_NAME:?WEBAPP_NAME is required}"
RESOURCE_GROUP="${RESOURCE_GROUP:?RESOURCE_GROUP is required}"
SLOT_NAME="${SLOT_NAME:-}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-18}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"

if [ -n "$SLOT_NAME" ]; then
  host="$(az webapp show \
    --name "$WEBAPP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --slot "$SLOT_NAME" \
    --query defaultHostName -o tsv)"
  scm_host="${host/.azurewebsites.net/.scm.azurewebsites.net}"
else
  scm_host="${WEBAPP_NAME}.scm.azurewebsites.net"
fi

scm_url="https://${scm_host}/"

echo "Waiting for SCM readiness at ${scm_url} (max ${MAX_ATTEMPTS} attempts)..."

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  set +e
  status="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' "$scm_url")"
  curl_exit=$?
  set -e

  if [ "$curl_exit" -ne 0 ]; then
    echo "Attempt ${attempt}/${MAX_ATTEMPTS}: curl failed (exit ${curl_exit})."
  elif [ "$status" = "503" ]; then
    echo "Attempt ${attempt}/${MAX_ATTEMPTS}: HTTP 503 (SCM not ready)."
  else
    echo "SCM is ready (HTTP ${status}) on attempt ${attempt}/${MAX_ATTEMPTS}."
    exit 0
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    sleep "$SLEEP_SECONDS"
  fi
done

echo "::error::SCM endpoint did not become ready: ${scm_url}"
exit 1
