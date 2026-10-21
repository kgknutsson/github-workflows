#!/usr/bin/env bash
# Write a GitHub Actions step summary with a coarse failure category for operators.
set -euo pipefail

PHASE="${PHASE:?PHASE is required (provision|deploy|verify|build)}"
DEPLOY_LOG="${DEPLOY_LOG:-}"
VERIFY_LOG="${VERIFY_LOG:-}"
BUILD_LOG="${BUILD_LOG:-}"

category="unknown"
headline="Preview workflow failed"
hint="Inspect the job log and Azure deployment logs for this slot."

classify_from_text() {
  local text="$1"
  if echo "$text" | grep -qiE 'HTTP_503|Kudu Status[[:space:]]*:[[:space:]]*503|503 Service Unavailable|Failed to warm-up Kudu|SCM endpoint did not become ready'; then
    category="platform_transient"
    headline="Transient Azure deploy platform error (Kudu / SCM)"
    hint="Re-run the failed jobs. This is usually not caused by application code."
    return 0
  fi
  if echo "$text" | grep -qiE 'Deployment slot limit|already has [0-9]+ deployment slots|User-assigned managed identity|not found in|AuthorizationFailed|does not have authorization|ResourceNotFound'; then
    category="platform_config"
    headline="Azure platform or access configuration error"
    hint="Check slot capacity, managed identity, RBAC, and resource names. Re-run alone may not help."
    return 0
  fi
  if echo "$text" | grep -qiE 'yarn|npm|pnpm|nx build|Build output directory was not found|ERR!|Command failed'; then
    category="build"
    headline="Build failed before deploy"
    hint="Fix the build in the pull request. Re-run alone may not help until code is fixed."
    return 0
  fi
  if echo "$text" | grep -qiE 'Post-deploy verification failed|Health check did not|HTTP 500|HTTP 502'; then
    category="app_runtime"
    headline="Deploy finished but the app did not become healthy"
    hint="Check app startup, health route, and slot logs. This may be application code or runtime config."
    return 0
  fi
  if echo "$text" | grep -qiE 'slot_name must|unsupported build env|Preflight|caller_prepare_script'; then
    category="workflow"
    headline="Workflow input or caller script error"
    hint="Fix workflow inputs or the caller prepare script."
    return 0
  fi
}

blob=""
for file in "$DEPLOY_LOG" "$VERIFY_LOG" "$BUILD_LOG"; do
  if [ -n "$file" ] && [ -f "$file" ]; then
    blob="${blob}$(cat "$file")"
  fi
done

classify_from_text "$blob"

summary_file="${GITHUB_STEP_SUMMARY:-/dev/null}"
{
  echo "## SPA App Service PR preview — ${headline}"
  echo ""
  echo "| Field | Value |"
  echo "| --- | --- |"
  echo "| Phase | \`${PHASE}\` |"
  echo "| Category | \`${category}\` |"
  echo ""
  echo "### What to do"
  echo ""
  echo "${hint}"
  echo ""
  if [ "$category" = "platform_transient" ]; then
    echo "Use **Re-run failed jobs** on this workflow run."
  fi
} >>"$summary_file"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "failure_category=${category}" >>"$GITHUB_OUTPUT"
fi

echo "Failure category: ${category} (${headline})"
