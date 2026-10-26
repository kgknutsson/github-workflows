#!/usr/bin/env bash
# Probe a slot URL after deploy. Supports Easy Auth redirects when accept_auth_redirect=true.
set -euo pipefail

SLOT_HOST="${SLOT_HOST:?SLOT_HOST is required}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
ACCEPT_AUTH_REDIRECT="${ACCEPT_AUTH_REDIRECT:-false}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-15}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
VERIFY_LOG="${VERIFY_LOG:-${RUNNER_TEMP:-/tmp}/spa-app-service-verify.log}"

case "$HEALTH_PATH" in
  "") echo "health_path is empty; skipping HTTP verification."; exit 0 ;;
  /*) path="$HEALTH_PATH" ;;
  *) path="/$HEALTH_PATH" ;;
esac

url="https://${SLOT_HOST}${path}"
echo "Verifying ${url} (accept_auth_redirect=${ACCEPT_AUTH_REDIRECT})..."

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  set +e
  headers="$(mktemp)"
  status="$(curl -sS -m 20 -D "$headers" -o /dev/null -w '%{http_code}' "$url")"
  curl_exit=$?
  location="$(grep -i '^location:' "$headers" | tail -n1 | cut -d' ' -f2- | tr -d '\r' || true)"
  rm -f "$headers"
  set -e

  {
    echo "attempt=${attempt}"
    echo "curl_exit=${curl_exit}"
    echo "status=${status}"
    echo "location=${location}"
  } >>"$VERIFY_LOG"

  if [ "$curl_exit" -ne 0 ]; then
    echo "Attempt ${attempt}/${MAX_ATTEMPTS}: curl failed (exit ${curl_exit})."
  elif [ "$status" = "200" ]; then
    echo "Verification passed (HTTP 200) on attempt ${attempt}/${MAX_ATTEMPTS}."
    exit 0
  elif [ "$ACCEPT_AUTH_REDIRECT" = "true" ] && [ "$status" = "302" ] && [ -n "$location" ] && echo "$location" | grep -qi 'login.microsoftonline.com'; then
    echo "Verification passed (HTTP 302 to Entra login) on attempt ${attempt}/${MAX_ATTEMPTS}."
    exit 0
  elif [ "$status" = "502" ] || [ "$status" = "503" ]; then
    echo "Attempt ${attempt}/${MAX_ATTEMPTS}: HTTP ${status} (platform warming)."
  else
    echo "Attempt ${attempt}/${MAX_ATTEMPTS}: HTTP ${status}."
  fi

  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    sleep "$SLEEP_SECONDS"
  fi
done

echo "::error::Post-deploy verification failed for ${url}. See ${VERIFY_LOG}."
exit 1
