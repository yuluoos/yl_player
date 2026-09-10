#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 -B "$repo_root/tool/check_public_surface.py" --root "$repo_root"
