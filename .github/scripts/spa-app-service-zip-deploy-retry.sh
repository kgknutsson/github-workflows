#!/usr/bin/env bash
# Zip-deploy to an App Service slot with retries for transient Kudu / platform errors.
set -euo pipefail

WEBAPP_NAME="${WEBAPP_NAME:?WEBAPP_NAME is required}"
RESOURCE_GROUP="${RESOURCE_GROUP:?RESOURCE_GROUP is required}"
ZIP_PATH="${ZIP_PATH:?ZIP_PATH is required}"
SLOT_NAME="${SLOT_NAME:-}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
DEPLOY_LOG="${DEPLOY_LOG:-${RUNNER_TEMP:-/tmp}/spa-app-service-deploy.log}"

deploy_once() {
  : >"$DEPLOY_LOG"
  set +e
  if [ -n "$SLOT_NAME" ]; then
    az webapp deploy \
      --name "$WEBAPP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --slot "$SLOT_NAME" \
      --src-path "$ZIP_PATH" \
      --type zip 2>&1 | tee "$DEPLOY_LOG"
  else
    az webapp deploy \
      --name "$WEBAPP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --src-path "$ZIP_PATH" \
      --type zip 2>&1 | tee "$DEPLOY_LOG"
  fi
  deploy_exit=${PIPESTATUS[0]}
  set -e
  return "$deploy_exit"
}

is_transient_deploy_failure() {
  grep -qiE 'HTTP_503|Kudu Status[[:space:]]*:[[:space:]]*503|503 Service Unavailable|Failed to warm-up Kudu|warm-up Kudu|Service Unavailable' "$DEPLOY_LOG"
}

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "Deploy attempt ${attempt}/${MAX_ATTEMPTS}..."
  if deploy_once; then
    echo "Deploy succeeded on attempt ${attempt}/${MAX_ATTEMPTS}."
    exit 0
  fi

  if ! is_transient_deploy_failure; then
    echo "Deploy failed with a non-transient error (no retry)."
    exit 1
  fi

  if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
    echo "Deploy failed after ${MAX_ATTEMPTS} attempts (transient platform errors)."
    exit 1
  fi

  sleep_seconds=$((attempt * 15))
  echo "Transient platform error detected. Retrying in ${sleep_seconds}s..."
  sleep "$sleep_seconds"
done

exit 1
