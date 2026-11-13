#!/usr/bin/env bash
# Regression: slot-start and slot-stop must exit 0 after the slot reaches the
# requested state. A RETURN trap on a local error file fails this under set -u.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
promotion_script="${script_dir}/azure-app-service-slot-promotion.sh"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat >"${work_dir}/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
action="${1:-}"
sub="${2:-}"
state_file="${AZ_FAKE_STATE:?}"
case "${action} ${sub}" in
  "webapp show")
    cat "$state_file"
    ;;
  "webapp start")
    printf 'Running\n' >"$state_file"
    ;;
  "webapp stop")
    printf 'Stopped\n' >"$state_file"
    ;;
  *)
    echo "unexpected az invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${work_dir}/az"

export PATH="${work_dir}:${PATH}"
export WEBAPP_NAME="app-test"
export RESOURCE_GROUP="rg-test"
export STAGING_SLOT="staging"
export AZ_FAKE_STATE="${work_dir}/state"

run_case() {
  local initial_state="$1"
  local command="$2"
  local expected="$3"
  printf '%s\n' "$initial_state" >"$AZ_FAKE_STATE"
  local output
  output="$(bash "$promotion_script" "$command")"
  printf '%s\n' "$output"
  if ! grep -Fq "$expected" <<<"$output"; then
    echo "Expected output to contain: ${expected}" >&2
    exit 1
  fi
}

run_case "Running" "slot-start" "Deploy slot 'staging' is already Running"
run_case "Stopped" "slot-start" "Start deploy slot: slot 'staging' is Running"
run_case "Stopped" "slot-stop" "Deploy slot 'staging' is already Stopped"
run_case "Running" "slot-stop" "Stop deploy slot: slot 'staging' is Stopped"

echo "Slot lifecycle commands exited 0."
