#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
exec python3 -B "$REPO_ROOT/tool/consumer_fixtures/apple_flutter/source_parity.py" "$@"
