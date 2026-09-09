"""Verify the endorsed example tests and their immutable migration origins.

Historical checks require the pinned pre-endorsement commit to exist locally.
The check never fetches repository history; shallow checkouts must fetch exactly
that commit before invoking it.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


PINNED_REVISION = "ce368c55ad291b163b02157b487dbbf798a69892"
HISTORICAL_MANIFESTS = {
    "tests-manifest.json": PINNED_REVISION,
    "engine-tests-manifest.json": PINNED_REVISION,
    "resources-manifest.json": PINNED_REVISION,
}
EXPECTED_CASES = {"ios": 251, "macos": 213}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require_revision(root, revision=PINNED_REVISION):
    result = subprocess.run(
        ["git", "-C", str(root), "cat-file", "-e", f"{revision}^{{commit}}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode:
        raise RuntimeError(
            "missing pinned historical revision "
            f"{revision}; shallow checkouts must run: "
            f"git fetch --no-tags --depth=1 origin {revision}"
        )


def git_blob(root, revision, path):
    require_revision(root, revision)
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"{revision}:{path}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise RuntimeError(
            f"historical fixture is missing at {revision}:{path}: "
            f"{result.stderr.decode(errors='replace').strip()}"
        )
    return result.stdout


def source_bytes(root, manifest_name, row):
    revision = HISTORICAL_MANIFESTS.get(manifest_name)
    if revision is not None:
        return git_blob(root, revision, row["source"])
    return (root / row["source"]).read_bytes()


def verify_historical_sources(root):
    root = Path(root).resolve()
    fixtures = root / "tool/consumer_fixtures/apple_flutter"
    require_revision(root)
    for manifest_name in HISTORICAL_MANIFESTS:
        rows = json.loads((fixtures / manifest_name).read_text())
        for row in rows:
            expected = row.get(
                "source_sha256", row.get("original_sha256", row.get("sha256"))
            )
            actual = digest(source_bytes(root, manifest_name, row))
            if actual != expected:
                raise RuntimeError(
                    f"historical source hash changed at {PINNED_REVISION}:"
                    f"{row['source']}: expected {expected}, got {actual}"
                )

        for row in rows:
            original = source_bytes(root, manifest_name, row)
            for retired in row.get("retired_methods", []):
                body = retired["original_body"].encode()
                if digest(body) != retired["original_body_sha256"]:
                    raise RuntimeError(
                        f"retired method body hash changed: {retired['method']}"
                    )
                if body not in original:
                    raise RuntimeError(
                        f"retired method body is absent from pinned source: "
                        f"{retired['method']}"
                    )

    for row in json.loads((fixtures / "task7-host-cases.json").read_text()):
        body = row["original_body"].encode()
        if digest(body) != row["original_body_sha256"]:
            raise RuntimeError(f"host transfer body hash changed: {row['method']}")
        if body not in git_blob(root, PINNED_REVISION, row["source"]):
            raise RuntimeError(
                f"host transfer body is absent from pinned source: "
                f"{row['source']}::{row['method']}"
            )


def accepted_tests(fixtures, platform):
    paths = list((fixtures / "RunnerTests").glob("*.swift"))
    paths += list((fixtures / f"RunnerTests-{platform}").glob("*.swift"))
    accepted = {}
    for path in paths:
        if path.name in accepted:
            raise RuntimeError(f"duplicate accepted fixture filename: {path.name}")
        accepted[path.name] = path.read_bytes()
    return accepted


def verify_current_targets(root):
    root = Path(root).resolve()
    fixtures = root / "tool/consumer_fixtures/apple_flutter"
    resources = {
        path.name: path.read_bytes()
        for path in (fixtures / "Resources").iterdir()
        if path.is_file()
    }
    for platform, expected_count in EXPECTED_CASES.items():
        target = root / f"packages/yl_player/example/{platform}/RunnerTests"
        accepted = accepted_tests(fixtures, platform)
        actual = {path.name: path.read_bytes() for path in target.glob("*.swift")}
        if actual != accepted:
            missing = sorted(set(accepted) - set(actual))
            extra = sorted(set(actual) - set(accepted))
            changed = sorted(
                name
                for name in set(actual) & set(accepted)
                if actual[name] != accepted[name]
            )
            raise RuntimeError(
                f"{platform} example tests differ from accepted fixtures: "
                f"missing={missing}, extra={extra}, changed={changed}"
            )
        actual_resources = {
            path.name: path.read_bytes()
            for path in target.iterdir()
            if path.is_file() and path.suffix != ".swift"
        }
        if actual_resources != resources:
            raise RuntimeError(
                f"{platform} example test resources differ from accepted fixtures"
            )
        text = b"\n".join(actual.values()).decode()
        count = len(re.findall(r"\bfunc test\w+\(", text))
        if count != expected_count:
            raise RuntimeError(
                f"{platform} example expected {expected_count} native cases, got {count}"
            )
        if "@testable import yl_player_ios" in text or "@testable import yl_player_macos" in text:
            raise RuntimeError(f"{platform} example retains a legacy testable import")
        if "@testable import yl_player_apple" not in text:
            raise RuntimeError(f"{platform} example does not test yl_player_apple")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--historical-only", action="store_true")
    group.add_argument("--current-only", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    if not args.current_only:
        verify_historical_sources(root)
        print(f"Historical Apple test provenance: {PINNED_REVISION} verified")
    if not args.historical_only:
        verify_current_targets(root)
        print("Current Apple example tests: iOS 251, macOS 213 verified")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        raise SystemExit(str(error)) from error
