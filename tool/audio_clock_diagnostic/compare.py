#!/usr/bin/env python3
"""Diagnostic A/B/A run; never replaces or relaxes the regular native gate.

Installs a pinned loopback driver only on an ephemeral GitHub-hosted runner.
The original default, post-CoreAudio-restart default, guest clock, and restored
default use the same test binary and exact PCM/EOF/resource assertions.
"""
import hashlib
import json
import os
import platform
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
EXAMPLE = ROOT / "packages/yl_player/example"
EVIDENCE = EXAMPLE / "build/audio-clock-evidence"
DRIVER_URL = "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg"
DRIVER_SHA256 = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise SystemExit("This diagnostic installs a driver only on a GitHub-hosted runner")
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    route = EVIDENCE / "output-route"
    run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreAudio",
         ROOT / "tool/media_matrix/output_route/probe.m", "-o", route])
    def devices():
        return json.loads(subprocess.check_output([str(route), "list"]))
    initial = devices()
    original_name = next(d["name"] for d in initial["devices"] if d["id"] == initial["default"])
    binary = EXAMPLE / "build/audio-clock-diagnostic/Build/Products/Debug/yl_player_example.app/Contents/PlugIns/RunnerTests.xctest/Contents/MacOS/RunnerTests"
    receipt = {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
               "driverURL": DRIVER_URL, "driverSHA256": DRIVER_SHA256, "initial": initial, "runs": [],
               "architecture": platform.machine(),
               "testBinarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
               "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
               "os": subprocess.check_output(["sw_vers"], text=True).strip()}
    def save():
        (EVIDENCE / "comparison.json").write_text(json.dumps(receipt, indent=2) + "\n")
    def select(name):
        # IDs can change when coreaudiod restarts; resolve the exact name anew.
        deadline = time.monotonic() + 30
        current = None
        while True:
            try:
                current = devices()
            except subprocess.CalledProcessError:
                # HAL can briefly be unavailable during the explicit restart.
                current = None
            matches = [d for d in current["devices"] if d["name"] == name and d["canBeDefault"]] if current else []
            if len(matches) == 1:
                run([route, "set", matches[0]["id"]])
                selected = devices()
                if selected["default"] == matches[0]["id"]:
                    return selected
            if time.monotonic() > deadline:
                raise RuntimeError(f"Cannot select unique output device {name!r}: {current}")
            time.sleep(0.5)
    def matrix(label, device_name, period=None):
        if hashlib.sha256(binary.read_bytes()).hexdigest() != receipt["testBinarySHA256"]:
            raise RuntimeError("Test binary changed between comparison arms")
        selected = devices() if period is not None else select(device_name)
        if period is not None and selected["default"] != initial["default"]:
            raise RuntimeError("Default output changed between period comparisons")
        result = EVIDENCE / f"{label}.xcresult"
        command = [sys.executable, "-B", str(ROOT / "tool/run_with_display_awake.py"),
                   "xcodebuild", "test-without-building", "CODE_SIGNING_ALLOWED=NO", "-quiet",
                   "-workspace", str(EXAMPLE / "macos/Runner.xcworkspace"), "-scheme", "Runner",
                   "-derivedDataPath", str(EXAMPLE / "build/audio-clock-diagnostic"),
                   "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
                   "-only-testing:RunnerTests/YlMacosAudioTests/testActualTerminalAdapterFrameSequenceMatrix",
                   "-resultBundlePath", str(result)]
        with (EVIDENCE / f"{label}.log").open("w") as log:
            env = os.environ.copy()
            if period is not None:
                env["TEST_RUNNER_YL_HOSTED_PCM_BUFFER"] = "1" if period == 4096 else "0"
            status = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=env).returncode
        summary = json.loads(subprocess.check_output([
            "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)]))
        (EVIDENCE / f"{label}-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        attachments = EVIDENCE / f"{label}-attachments"
        run(["xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", attachments])
        pcm_rows = []
        render_sizes = {}
        for path in sorted(attachments.iterdir()):
            if not path.is_file() or path.name == "manifest.json":
                continue
            try:
                value = json.loads(path.read_bytes())
            except (ValueError, UnicodeError):
                continue
            if isinstance(value, dict) and value.get("kind") == "nativeRenderTrace" and value.get("path") == "matrix":
                trace = value["trace"]
                identity = (value["candidate"], value["buffers"], value["starvation"], value["pausedEOF"])
                sizes = {r[3] for r in trace["entries"] if r[5] & trace["preRenderMask"]}
                if identity in render_sizes:
                    raise RuntimeError(f"Duplicate render trace for {identity}")
                render_sizes[identity] = sorted(sizes)
            if isinstance(value, dict) and "marker" in value:
                pcm = {key: value[key] for key in ("kind", "candidate", "buffers", "starvation", "pausedEOF",
                       "marker", "submittedMarker", "pending", "failures", "peakBytes") if key in value}
                pcm["attachment"] = path.name
                pcm_rows.append(pcm)
        row = {"label": label, "route": selected, "exitCode": status,
               "passedTests": summary["passedTests"], "failedTests": summary["failedTests"],
               "skippedTests": summary["skippedTests"], "testFailures": summary.get("testFailures", []),
               "pcmRows": pcm_rows, "renderSlices": [{"identity": k, "frames": v} for k, v in sorted(render_sizes.items())]}
        receipt["runs"].append(row); save()
        print(json.dumps(row, sort_keys=True), flush=True)
        diagnostic = {"device": device_name, "passedTests": row["passedTests"], "failedTests": row["failedTests"],
                      "rows": len(pcm_rows), "losses": [{"candidate": p.get("candidate"), "kind": p.get("kind", "matrix"),
                      "buffers": p["buffers"], "missingFrames": p["buffers"] * 1024 - p["marker"]["frames"],
                      "errors": p["marker"]["errors"]} for p in pcm_rows
                      if p["marker"]["frames"] != p["buffers"] * 1024 or p["marker"]["errors"]]}
        print(f"::notice title=Audio matrix {label}::{json.dumps(diagnostic, sort_keys=True)}", flush=True)
        expected = {(candidate, count, False, False) for candidate in (False, True) for count in (0, 1, 3, 2000)}
        expected |= {(candidate, 100, True, False) for candidate in (False, True)}
        expected |= {(candidate, 3, False, True) for candidate in (False, True)}
        actual = [(p["candidate"], p["buffers"], p["starvation"], p["pausedEOF"]) for p in pcm_rows if "candidate" in p]
        if period is not None:
            measured = set(size for sizes in render_sizes.values() for size in sizes)
            print(f"::notice title=I/O period {label}::expected={period} measured={sorted(measured)} "
                  f"traces={len(render_sizes)}", flush=True)
            if set(render_sizes) != expected or any(
                sizes != [period] for key, sizes in render_sizes.items() if key[1] or sizes
            ):
                raise RuntimeError(f"Render traces do not confirm {period}-frame period for all matrix rows")
        return (status == 0 and row["passedTests"] == 1 and row["failedTests"] == 0 and row["skippedTests"] == 0
                and len(actual) == len(expected) and set(actual) == expected)
    save()
    if sys.argv[1:] == ["--io-period"]:
        # A/B/B/A: last run verifies restoration on the same default device.
        matrix("original-before", original_name, 512)
        first = matrix("long-period-1", original_name, 4096)
        second = matrix("long-period-2", original_name, 4096)
        matrix("original-restored", original_name, 512)
        receipt["longPeriodAllPassed"] = first and second
        save()
        return 0 if first and second else 1
    try:
        package = EVIDENCE / "BlackHole2ch-0.7.1.pkg"
        # The vendor rejects Python urllib's user agent with HTTP 406. Use the
        # standard curl download path, retaining TLS and pinned digest checks.
        run(["curl", "--fail", "--location", "--retry", "2", "--max-time", "120", "--output", package, DRIVER_URL])
        actual = hashlib.sha256(package.read_bytes()).hexdigest()
        if actual != DRIVER_SHA256:
            raise RuntimeError(f"Driver SHA256 mismatch: {actual}")
        matrix("default-before", original_name)
        run(["sudo", "installer", "-pkg", package, "-target", "/"])
        # No app is running now. Reload the new HAL plugin on this disposable VM.
        run(["sudo", "killall", "coreaudiod"])
        matrix("default-after-restart", original_name)
        guest_passes = [matrix(f"guest-clock-{i}", "BlackHole 2ch") for i in range(1, 4)]
        matrix("default-restored", original_name)
        receipt["guestClockAllPassed"] = all(guest_passes)
        save()
        return 0 if all(guest_passes) else 1
    finally:
        receipt["restored"] = select(original_name)
        save()


if __name__ == "__main__":
    sys.exit(main())
