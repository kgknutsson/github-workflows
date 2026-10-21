#!/usr/bin/env bash
# Run a caller-provided script path safely (no shell interpolation of the path).
set -euo pipefail

script="${CALLER_SCRIPT_PATH:-}"
if [ -z "$script" ]; then
  echo "::error::CALLER_SCRIPT_PATH is empty."
  exit 1
fi
case "$script" in
  *[!a-zA-Z0-9/_.-]*|'')
    echo "::error::Caller script path contains unsupported characters: $script"
    exit 1
    ;;
esac
if [ "${script#../}" != "$script" ] || [ "${script#/}" != "$script" ]; then
  echo "::error::Caller script path must be relative to the repository root."
  exit 1
fi
if [ ! -f "$script" ]; then
  echo "::error::Caller script not found: $script"
  exit 1
fi
bash "$script"
