#!/usr/bin/env bash
# Warmup setting verification is read-only and runs before slot swap.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
promotion_script="${script_dir}/azure-app-service-slot-promotion.sh"
workflow="${script_dir}/../workflows/azure-app-service-slot-promotion.yml"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

if grep -Eq 'appsettings[[:space:]]+set' "$promotion_script" "$workflow"; then
  echo "Slot promotion must not write app settings." >&2
  exit 1
fi

warmup_line="$(grep -n 'Verify slot warmup settings' "$workflow" | head -n 1 | cut -d: -f1)"
promote_line="$(grep -n 'Promote staging slot via ARM' "$workflow" | head -n 1 | cut -d: -f1)"
if [[ -z "$warmup_line" || -z "$promote_line" || "$warmup_line" -ge "$promote_line" ]]; then
  echo "Warmup verification must run before promotion." >&2
  exit 1
fi

cat >"${work_dir}/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log="${AZ_FAKE_LOG:?}"
settings="${AZ_FAKE_SETTINGS:?}"
printf '%s\n' "$*" >>"$log"
if [[ "${AZ_FAKE_FAIL:-}" == "1" ]]; then
  echo "fake az read failed" >&2
  exit 1
fi
if [[ "${1:-}" != "webapp" || "${2:-}" != "config" || "${3:-}" != "appsettings" || "${4:-}" != "list" ]]; then
  echo "unexpected az invocation: $*" >&2
  exit 1
fi
slot=""
query=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot)
      slot="$2"
      shift 2
      ;;
    --query)
      query="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
name="$(printf '%s' "$query" | sed -n "s/.*name=='\\([^']*\\)'.*/\\1/p")"
if [[ -z "$slot" || -z "$name" ]]; then
  echo "could not parse slot or setting" >&2
  exit 1
fi
line="$(grep -F -m 1 "${slot}|${name}|" "$settings" || true)"
if [[ -z "$line" ]]; then
  printf '\n'
  exit 0
fi
value="${line#${slot}|${name}|}"
printf '%s\n' "$value"
EOF
chmod +x "${work_dir}/az"

export AZ_FAKE_LOG="${work_dir}/az.log"
export AZ_FAKE_SETTINGS="${work_dir}/settings"
export PATH="${work_dir}:${PATH}"
export WEBAPP_NAME="app-test"
export RESOURCE_GROUP="rg-test"

reset_case() {
  : >"$AZ_FAKE_LOG"
  : >"$AZ_FAKE_SETTINGS"
  unset AZ_FAKE_FAIL
}

write_setting() {
  printf '%s\n' "$1|$2|$3" >>"$AZ_FAKE_SETTINGS"
}

write_match() {
  local slot="$1"
  local path="$2"
  local statuses="$3"
  local warmup="${4-}"
  write_setting "$slot" "WEBSITE_SWAP_WARMUP_PING_PATH" "$path"
  write_setting "$slot" "WEBSITE_SWAP_WARMUP_PING_STATUSES" "$statuses"
  if [[ -n "$warmup" ]]; then
    write_setting "$slot" "WEBSITE_WARMUP_PATH" "$warmup"
  fi
}

run_check() {
  local staging_slot="$1"
  shift
  env \
    STAGING_SLOT="$staging_slot" \
    "$@" \
    bash "$promotion_script" warmup-settings-check
}

expect_ok() {
  local expected="$1"
  shift
  local output
  output="$(run_check "$@")"
  printf '%s\n' "$output"
  if ! grep -Fq "$expected" <<<"$output"; then
    echo "Expected output to contain: ${expected}" >&2
    exit 1
  fi
}

expect_fail() {
  local expected="$1"
  shift
  local output status
  set +e
  output="$(run_check "$@" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "Expected warmup verification to fail." >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    echo "Expected failure to contain: ${expected}" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ "$expected" != *"Apply Terraform"* ]] && grep -Fq "Apply Terraform" <<<"$output"; then
    echo "Read failure must not look like a setting mismatch." >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

reset_case
expect_ok "Skipping warmup setting verification." staging \
  SWAP_WARMUP_PING_PATH="" \
  WARMUP_PATH="/api/health/live"
if [[ -s "$AZ_FAKE_LOG" ]]; then
  echo "Empty ping path must not read app settings." >&2
  exit 1
fi

reset_case
write_match production "/api/health/live" "200" "/api/health/live"
write_match staging "/api/health/live" "200" "/api/health/live"
expect_ok "Slot production warmup settings match." staging \
  SWAP_WARMUP_PING_PATH="/api/health/live" \
  WARMUP_PATH="/api/health/live"
expect_ok "Slot staging warmup settings match." staging \
  SWAP_WARMUP_PING_PATH="/api/health/live" \
  WARMUP_PATH="/api/health/live"

reset_case
write_match production "/live" "200,202"
write_match staging "/live" "200,202"
expect_ok "Slot staging warmup settings match." staging \
  SWAP_WARMUP_PING_PATH="/live" \
  SWAP_WARMUP_PING_STATUSES="200,202"
if grep -Fq "WEBSITE_WARMUP_PATH" "$AZ_FAKE_LOG"; then
  echo "Empty warmup-path must not read WEBSITE_WARMUP_PATH." >&2
  exit 1
fi

reset_case
write_match production "/" "200" "/api/health/live"
write_match staging "/api/health/live" "200" "/api/health/live"
expect_fail "Slot production WEBSITE_SWAP_WARMUP_PING_PATH is '/'. Apply Terraform so it is /api/health/live." staging \
  SWAP_WARMUP_PING_PATH="/api/health/live" \
  WARMUP_PATH="/api/health/live"

reset_case
write_match production "/api/health/live" "200" "/api/health/live"
write_setting staging "WEBSITE_SWAP_WARMUP_PING_PATH" "/api/health/live"
write_setting staging "WEBSITE_WARMUP_PATH" "/api/health/live"
expect_fail "Slot staging WEBSITE_SWAP_WARMUP_PING_STATUSES is 'unset'. Apply Terraform so it is 200." staging \
  SWAP_WARMUP_PING_PATH="/api/health/live" \
  WARMUP_PATH="/api/health/live"

reset_case
write_match production "/api/health/live" "200" "/api/health/live"
write_match green "/api/health/live" "200" "/api/health/live"
expect_ok "Slot green warmup settings match." green \
  SWAP_WARMUP_PING_PATH="/api/health/live" \
  WARMUP_PATH="/api/health/live"

reset_case
write_match production "/api/health/live" "200"
export AZ_FAKE_FAIL=1
expect_fail "Failed to read App Service setting 'WEBSITE_SWAP_WARMUP_PING_PATH' on slot 'production'." staging \
  SWAP_WARMUP_PING_PATH="/api/health/live"

echo "Slot warmup setting checks passed."
