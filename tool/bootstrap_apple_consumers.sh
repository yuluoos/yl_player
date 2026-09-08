#!/bin/sh
set -eu
if [ -z "${YL_REPO_ROOT:-}" ]; then
  YL_REPO_ROOT=$(git rev-parse --show-toplevel)
fi
export YL_REPO_ROOT
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 -B "$SCRIPT_DIR/consumer_fixtures/apple_flutter/consumers.py" bootstrap "$@"
