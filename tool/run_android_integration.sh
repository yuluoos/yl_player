#!/bin/sh
# Stable entry point; Python owns bounded command groups and exit receipts.
set -eu
exec python3 "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/run_android_integration.py" "$@"
