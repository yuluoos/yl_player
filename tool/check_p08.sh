#!/bin/sh
# Local engineering validation and an explicit, non-publishing release gate.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
case "${1:---validate}" in
  --validate)
    python3 -B -m unittest discover -s tool/playback_benchmark -p 'test_*.py'
    (cd packages/yl_player/example && "${YL_FLUTTER:-flutter}" test test)
    python3 -B tool/playback_benchmark/threshold_registry.py
    python3 -B tool/release_readiness/check.py
    echo 'P08_ENGINEERING_VALIDATED performance_and_release_admission=false'
    ;;
  --require-ready)
    # Both must pass; a valid/pending inventory is never interpreted as success.
    python3 -B tool/playback_benchmark/threshold_registry.py --require-ready
    python3 -B tool/release_readiness/check.py --require-ready
    echo 'P08_READINESS_EVIDENCE_VALIDATED publication_authorized=false'
    ;;
  *) echo 'usage: check_p08.sh [--validate|--require-ready]' >&2; exit 64 ;;
esac
