#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 - "$SCRIPT_DIR" "$@" <<'PY'
import collections
import hashlib
import json
from pathlib import Path
import subprocess
import sys

tool = Path(sys.argv[1]).resolve()
root = tool.parents[2]
manifest_path = tool / "source-parity.json"
mode = sys.argv[2:]
if mode not in (["--capture"], ["--verify-identical"]):
    sys.exit("usage: check_source_parity.sh --capture|--verify-identical")

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

destinations = {
    "YlByteRingBuffer": "Shared/FFmpeg",
    "YlByteSource": "Shared/FFmpeg",
    "YlBoundedPacketQueue": "Shared/FFmpeg",
    "YlFallbackBufferBudget": "Shared/FFmpeg",
    "YlOpenedMedia": "Shared/FFmpeg",
    "YlNetworkByteSource": "Shared/Network",
    "YlNetworkRequestPolicy": "Shared/Network",
    "YlHlsHeaderPolicy": "Shared/HLS",
    "YlHlsManifestRewriter": "Shared/HLS",
    "YlHlsURLCodec": "Shared/HLS",
    "YlFallbackStateEncoder": "Shared/Metrics",
    "YlFallbackTrackCatalog": "Shared/Metrics",
    "YlFallbackQualityPolicy": "Engines/ManagedFallback",
}
source_root = "packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple"
trees = {
    platform: {p.name: p for p in (root / f"packages/yl_player_{platform}/{platform}/yl_player_{platform}/Sources/yl_player_{platform}").glob("*.swift")}
    for platform in ("ios", "macos")
}
if not all(trees.values()):
    sys.exit("legacy Apple source trees missing from active checkout")

if mode == ["--capture"]:
    rows = []
    for name in sorted(trees["ios"].keys() | trees["macos"].keys()):
        row = {"name": name}
        for platform in trees:
            path = trees[platform].get(name)
            row[platform] = str(path.relative_to(root)) if path else None
            row[platform + "_sha256"] = digest(path) if path else None
        if row["ios"] and row["macos"]:
            row["status"] = "identical" if row["ios_sha256"] == row["macos_sha256"] else "divergent"
        else:
            row["status"] = "ios_only" if row["ios"] else "macos_only"
        chosen = row["ios"] if row["status"] in ("identical", "ios_only") else row["macos"] if row["status"] == "macos_only" else None
        row["chosen_source"] = chosen
        directory = destinations.get(Path(name).stem)
        row["destination"] = f"{source_root}/{directory}/{name}" if directory and chosen else None
        if directory and row["status"] not in ("identical", "ios_only"):
            sys.exit(f"expected migration candidate is now divergent: {name}")
        row["adaptations"] = []
        rows.append(row)
    head = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True)
    manifest = {"schema_version": 1, "checkpoint": head.stdout.strip() if head.returncode == 0 else None, "sources": rows}
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(dict(collections.Counter(row["status"] for row in rows)), sort_keys=True))
    print(f"Captured {manifest_path}")
else:
    if not manifest_path.is_file():
        sys.exit("source manifest missing; run --capture at the pre-move checkpoint")
    manifest = json.loads(manifest_path.read_text())
    failures = []
    count = 0
    for row in manifest["sources"]:
        for platform in trees:
            relative = row[platform]
            if relative and (not (root / relative).is_file() or digest(root / relative) != row[platform + "_sha256"]):
                failures.append(f"baseline source hash changed: {relative}")
        if not row["destination"]:
            continue
        target = root / row["destination"]
        if not target.is_file():
            failures.append(f"missing shared source: {row['destination']}")
        else:
            chosen_platform = "ios" if row["chosen_source"] == row["ios"] else "macos"
            if digest(target) != row[chosen_platform + "_sha256"]:
                failures.append(f"shared source hash changed: {row['destination']}")
        count += 1
    if failures:
        sys.exit("\n".join(failures))
    declarations_path = tool / "source-declarations.json"
    if declarations_path.is_file():
        declarations = json.loads(declarations_path.read_text())["extractions"]
        for declaration in declarations:
            for origin in declaration["origins"]:
                lines = (root / origin["path"]).read_bytes().splitlines(keepends=True)
                extracted = b"".join(lines[origin["start_line"] - 1:origin["end_line"]])
                if hashlib.sha256(extracted).hexdigest() != declaration["declaration_sha256"]:
                    failures.append(f"extracted declaration changed: {origin['path']}:{origin['start_line']}")
            target = root / declaration["destination"]
            if not target.is_file() or digest(target) != declaration["destination_sha256"]:
                failures.append(f"shared declaration file changed: {declaration['destination']}")
        if failures:
            sys.exit("\n".join(failures))
        print(f"Verified {len(declarations)} exact paired production declaration extractions.")
    print(f"Verified {count} byte-identical shared copies and all recorded baseline hashes.")
PY
