"""Real Flutter consumer hosts. Generated state and command evidence stay outside Git."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

from main_example_tests import source_bytes, expected_identities, verify_result_bundle


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


ROOT = Path(os.environ["YL_REPO_ROOT"]).resolve()
FIXTURES = Path(__file__).resolve().parent
require(ROOT == FIXTURES.parents[2], "YL_REPO_ROOT must identify this script's active checkout")
actual = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "--show-toplevel"], text=True).strip()
require(Path(actual).resolve() == ROOT, "YL_REPO_ROOT is not a Git checkout root")
os.environ["YL_REPO_ROOT"] = str(ROOT)
identity = hashlib.sha256(str(ROOT).encode()).hexdigest()[:12]
OUTPUT = Path(os.environ.get("YL_APPLE_CONSUMERS", str(Path(tempfile.gettempdir()) / f"yl-apple-consumers-{identity}"))).resolve()
require(not OUTPUT.is_relative_to(ROOT), "Generated consumers must be outside the tracked checkout")
OUTPUT.mkdir(parents=True, exist_ok=True)
LOGS = Path(os.environ.get("YL_APPLE_LOG_DIR", str(OUTPUT / "logs"))).resolve()
LOGS.mkdir(parents=True, exist_ok=True)
FLUTTER = os.environ.get("YL_FLUTTER") or shutil.which("flutter")
require(FLUTTER is not None, "Set YL_FLUTTER to the installed Flutter executable")
ENV = os.environ.copy()
ENV.update({"YL_REPO_ROOT": str(ROOT), "COCOAPODS_DISABLE_STATS": "true", "PUB_CACHE": str(OUTPUT / "pub-cache")})


def run(command, cwd, name, capture=False):
    stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns() % 1000000000:09d}"
    path = LOGS / f"{stamp}-{name}.txt"
    record = {"command": [str(x) for x in command], "cwd": str(cwd), "repo_root": str(ROOT), "log": str(path)}
    print(f"{name}: {path}", flush=True)
    with path.open("w") as log:
        log.write(json.dumps(record) + "\n")
        log.flush()
        result = subprocess.run(command, cwd=cwd, env=ENV, stdout=log, stderr=subprocess.STDOUT)
    record["exit_code"] = result.returncode
    path.with_suffix(".json").write_text(json.dumps(record, indent=2) + "\n")
    if result.returncode:
        print(path.read_text()[-16000:], file=sys.stderr)
        raise RuntimeError(f"{name} failed with exit {result.returncode}; see {path}")
    return path.read_text().split("\n", 1)[1] if capture else path


def pubspec(manager):
    return f"""name: apple_consumer
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.12.0
dependencies:
  flutter:
    sdk: flutter
  yl_player_apple:
    path: {json.dumps(str(ROOT / 'packages/yl_player_apple'))}
  yl_player_platform_interface:
    path: {json.dumps(str(ROOT / 'packages/yl_player_platform_interface'))}
dependency_overrides:
  yl_player_apple:
    path: {json.dumps(str(ROOT / 'packages/yl_player_apple'))}
  yl_player_platform_interface:
    path: {json.dumps(str(ROOT / 'packages/yl_player_platform_interface'))}
dev_dependencies:
  flutter_test:
    sdk: flutter
flutter:
  config:
    enable-swift-package-manager: {'true' if manager == 'swiftpm' else 'false'}
"""


def verify_fixtures():
    for name in ["tests-manifest.json", "resources-manifest.json", "engine-tests-manifest.json"]:
        rows = json.loads((FIXTURES / name).read_text())
        for row in rows:
            destination = ROOT / row["destination"]
            expected_source = row.get("source_sha256", row.get("original_sha256", row.get("sha256")))
            expected_destination = row.get("destination_sha256", row.get("sha256"))
            require(hashlib.sha256(source_bytes(ROOT, name, row)).hexdigest() == expected_source,
                    f"Original fixture changed: {row['source']}")
            if expected_destination is not None:
                require(hashlib.sha256(destination.read_bytes()).hexdigest() == expected_destination,
                        f"Migrated fixture changed: {destination}")
    for row in json.loads((FIXTURES / "new-tests-manifest.json").read_text()):
        require(hashlib.sha256((ROOT / row["destination"]).read_bytes()).hexdigest() == row["sha256"],
                "New characterization fixture changed without an updated manifest")


def fixture_tests(platform):
    return list((FIXTURES / "RunnerTests").glob("*.swift")) + list((FIXTURES / ("RunnerTests-" + platform)).glob("*.swift"))


def sync_fixtures(host, platform, manager):
    verify_fixtures()
    tests = host / platform / "RunnerTests"
    for existing in tests.glob("*.swift"):
        if existing.name not in {p.name for p in fixture_tests(platform)}:
            existing.unlink()
    for source in fixture_tests(platform):
        shutil.copyfile(source, tests / source.name)
    # Existing tests use both bundle resources and paths relative to #filePath.
    shutil.copytree(FIXTURES / "Resources", host / "assets/test_media", dirs_exist_ok=True)
    for resource in (FIXTURES / "Resources").iterdir():
        if resource.is_file():
            shutil.copyfile(resource, tests / resource.name)
    run(["ruby", str(FIXTURES / "configure_project.rb"), str(host), platform, manager, str(FIXTURES)], ROOT, f"{platform}-{manager}-fixtures")


def bootstrap(platform, manager):
    host = OUTPUT / f"{platform}-{manager}"
    marker = host / "consumer.json"
    pending = host / "bootstrap-owner.json"
    if marker.is_file():
        saved = json.loads(marker.read_text())
        require(saved["repo_root"] == str(ROOT), "Consumer belongs to another checkout")
        sync_fixtures(host, platform, manager)
        if manager == "cocoapods":
            run(["pod", "install"], host / platform, f"{platform}-{manager}-refresh-pods")
        verify_graph(host, platform, manager)
        return host
    require(not host.exists() or (pending.is_file() and json.loads(pending.read_text())["repo_root"] == str(ROOT)), f"Unowned host exists at {host}; choose a fresh YL_APPLE_CONSUMERS directory")
    host.mkdir(exist_ok=True)
    pending.write_text(json.dumps({"repo_root": str(ROOT)}) + "\n")
    (host / "pubspec.yaml").write_text(pubspec(manager))
    run([FLUTTER, "create", "--no-pub", "--platforms", platform, "--project-name", "apple_consumer", str(host)], ROOT, f"{platform}-{manager}-create")
    (host / "pubspec.yaml").write_text(pubspec(manager))
    shutil.copyfile(FIXTURES / "main.dart", host / "lib/main.dart")
    tests = host / platform / "RunnerTests"
    for generated in tests.glob("*.swift"):
        generated.unlink()
    for source in fixture_tests(platform):
        shutil.copyfile(source, tests / source.name)
    shutil.copyfile(FIXTURES / "Resources/h264_aac.mkv", tests / "h264_aac.mkv")
    if manager == "cocoapods":
        shutil.copyfile(FIXTURES / f"Podfile-{platform}", host / platform / "Podfile")
        # Flutter's standard pre-action is only necessary for SwiftPM.
        scheme = host / platform / "Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme"
        scheme.write_text(re.sub(r"\s*<PreActions>.*?</PreActions>", "", scheme.read_text(), flags=re.S))
    run(["ruby", str(FIXTURES / "configure_project.rb"), str(host), platform, manager, str(FIXTURES)], ROOT, f"{platform}-{manager}-configure")
    if platform == "ios":
        info = host / "ios/Flutter/AppFrameworkInfo.plist"
        data = plistlib.loads(info.read_bytes())
        data["MinimumOSVersion"] = "15.0"
        info.write_bytes(plistlib.dumps(data))
    run([FLUTTER, "pub", "get"], host, f"{platform}-{manager}-pub-get")
    command = [FLUTTER, "build", platform, "--config-only", "--debug", "--no-pub"]
    if platform == "ios":
        command += ["--simulator", "--no-codesign"]
    run(command, host, f"{platform}-{manager}-config-build")
    if manager == "cocoapods":
        # Keep CocoaPods' full integration warnings; Flutter abbreviates successful installs.
        run(["pod", "install"], host / platform, f"{platform}-{manager}-pod-install")
    # Floors apply to generated aggregators and every app/test/aggregate target.
    for manifest in (host / platform / "Flutter/ephemeral/Packages").glob("*/Package.swift"):
        text = manifest.read_text()
        text = re.sub(r'\.iOS\([^)]*\)', '.iOS("15.0")', text)
        text = re.sub(r'\.macOS\([^)]*\)', '.macOS("12.0")', text)
        manifest.write_text(text)
    sync_fixtures(host, platform, manager)
    verify_graph(host, platform, manager)
    marker.write_text(json.dumps({"repo_root": str(ROOT), "platform": platform, "manager": manager}, indent=2) + "\n")
    return host


def verify_graph(host, platform, manager):
    native = host / platform
    expected_tests = {path.name: path.read_bytes() for path in fixture_tests(platform)}
    host_tests = {path.name: path.read_bytes() for path in (native / "RunnerTests").glob("*.swift")}
    require(expected_tests == host_tests, "Consumer characterization suites differ from current fixtures; choose a fresh consumer root")
    require((host / "lib/main.dart").read_bytes() == (FIXTURES / "main.dart").read_bytes(), "Consumer application differs from its fixture")
    for resource in (FIXTURES / "Resources").iterdir():
        require((native / "RunnerTests" / resource.name).read_bytes() == resource.read_bytes(), "Bundled consumer resource changed")
        require((host / "assets/test_media" / resource.name).read_bytes() == resource.read_bytes(), "Source-relative consumer resource changed")
    project = (native / "Runner.xcodeproj/project.pbxproj").read_text()
    plugins = json.loads((host / ".flutter-plugins-dependencies").read_text())
    names = {item["name"] for item in plugins["plugins"][platform]}
    require(plugins["swift_package_manager_enabled"][platform] == (manager == "swiftpm"), "Flutter selected an unexpected package manager")
    require(names == {"yl_player_apple"}, f"Unexpected native plugin registrations: {names}")
    plugin = plugins["plugins"][platform][0]
    require(Path(plugin["path"]).resolve() == ROOT / "packages/yl_player_apple", "Plugin path does not target active checkout")
    generated = native / "Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
    if manager == "swiftpm":
        require("FlutterGeneratedPluginSwiftPackage" in project and generated.is_file(), "SwiftPM graph is missing")
        require(not (native / "Podfile.lock").exists(), "SwiftPM consumer silently used CocoaPods")
        text = generated.read_text()
        require("yl_player_apple" in text, "Generated SwiftPM graph omits plugin")
        floor = '.iOS("15.0")' if platform == "ios" else '.macOS("12.0")'
        require(floor in text, "Generated SwiftPM aggregator has incorrect deployment floor")
    else:
        require("FlutterGeneratedPluginSwiftPackage" not in project, "CocoaPods consumer retains SwiftPM linkage")
        lock = native / "Podfile.lock"
        require(lock.is_file() and "yl_player_apple" in lock.read_text(), "CocoaPods graph is missing")
    floor = "15.0" if platform == "ios" else "12.0"
    key = "IPHONEOS_DEPLOYMENT_TARGET" if platform == "ios" else "MACOSX_DEPLOYMENT_TARGET"
    found = re.findall(key + r" = ([^;]+);", project)
    require(found and all(value.strip('"') == floor for value in found), "Consumer deployment floors differ")


def check(platform, manager, link):
    diagnostics = os.environ.get("YL_APPLE_TEST_DIAGNOSTICS")
    require(diagnostics is None or diagnostics == "never",
            "YL_APPLE_TEST_DIAGNOSTICS must be unset or exactly 'never'")
    require(diagnostics is None or not link,
            "YL_APPLE_TEST_DIAGNOSTICS applies only to unit-test gates")
    host = bootstrap(platform, manager)
    native = host / platform
    destination = "platform=macOS,arch=" + subprocess.check_output(["uname", "-m"], text=True).strip()
    if platform == "ios":
        devices = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"], ROOT, "simulators", capture=True))
        requested = os.environ.get("YL_IOS_SIMULATOR")
        available = [(runtime, device) for runtime, group in devices["devices"].items() for device in group if device.get("isAvailable") and "iPhone" in device["name"]]
        matches = [(runtime, device) for runtime, device in available if not requested or device["udid"] == requested]
        require(matches, "Requested iPhone simulator is unavailable")
        runtime, device = matches[0]
        destination = "platform=iOS Simulator,id=" + device["udid"]
        (LOGS / f"{platform}-{manager}-destination.json").write_text(json.dumps({"runtime": runtime, "device": device}, indent=2) + "\n")
    attempt = str(time.time_ns())
    result = host / f"results-{attempt}.xcresult"
    derived = host / ("derived-link" if link else "derived")
    run(["ruby", str(FIXTURES / "verify_project.rb"), str(host), platform, manager], ROOT, f"{platform}-{manager}-target-floors")
    run([FLUTTER, "--version"], ROOT, f"{platform}-{manager}-flutter-version")
    run(["sw_vers"], ROOT, f"{platform}-{manager}-host-os")
    run(["xcodebuild", "-version"], ROOT, f"{platform}-{manager}-xcode-version")
    command = ["xcodebuild", "-workspace", str(native / "Runner.xcworkspace"), "-scheme", "Runner", "-configuration", "Debug", "-destination", destination,
               "-parallel-testing-enabled", "NO",
               "-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", str(host / "source-packages"), "-packageCachePath", str(host / "package-cache"), "-disablePackageRepositoryCache",
               "-resultBundlePath", str(result), "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO", "build" if link else "test"]
    if diagnostics == "never":
        command.extend(["-collect-test-diagnostics", "never"])
    run(command, host, f"{platform}-{manager}-{'link' if link else 'unit'}")
    verify_graph(host, platform, manager)
    verify_product(host, platform, manager, derived=derived, expect_tests=not link)
    if link:
        print(json.dumps({"platform": platform, "manager": manager, "link": "passed", "result": str(result)}), flush=True)
        return
    summary = json.loads(run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], ROOT, f"{platform}-{manager}-summary", capture=True))
    expected_count = len(expected_identities(FIXTURES, platform))
    require(expected_count > 0 and summary.get("failedTests") == 0 and summary.get("passedTests", 0) + summary.get("skippedTests", 0) == expected_count and summary.get("totalTestCount") == expected_count, "Native result does not cover the complete fixture suite")
    # R21 restores the original third iOS host-case hardware condition. Exact
    # identities remain mandatory below; this count never grants another skip.
    allowed_skip_count = len(json.loads((FIXTURES / "allowed-hardware-skips.json").read_text())[platform])
    require(summary.get("skippedTests", 0) <= allowed_skip_count, "Unexpected characterization skips")
    verify_cases(result, platform, manager)
    (LOGS / f"{platform}-{manager}-result.json").write_text(json.dumps({"result_bundle": str(result), "summary": summary}, indent=2) + "\n")
    print(json.dumps({"platform": platform, "manager": manager, "passed": summary["passedTests"], "result": str(result)}), flush=True)


def verify_cases(result, platform, manager):
    verify_result_bundle(ROOT, result, platform, LOGS / f"{platform}-{manager}-runtime")


def verify_product(host, platform, manager, derived=None, expect_tests=True):
    products = (derived or host / "derived") / "Build/Products" / ("Debug" if platform == "macos" else "Debug-iphonesimulator")
    apps = list(products.glob("*.app"))
    require(len(apps) == 1, f"Expected one built consumer app, found {apps}")
    app = apps[0]
    contents = app / "Contents" if platform == "macos" else app
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    executable = (contents / "MacOS" if platform == "macos" else contents) / info["CFBundleExecutable"]
    frameworks = contents / "Frameworks"
    engine = "FlutterMacOS" if platform == "macos" else "Flutter"
    for name in [engine, "YlFFmpegBridge"]:
        require((frameworks / f"{name}.framework" / name).is_file(), f"Built host does not embed {name}")
    slice_id = "macos-arm64_x86_64" if platform == "macos" else "ios-arm64_x86_64-simulator"
    original_bridge = ROOT / "packages/yl_player_apple/darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework" / slice_id / "YlFFmpegBridge.framework/YlFFmpegBridge"
    embedded_bridge = frameworks / "YlFFmpegBridge.framework/YlFFmpegBridge"
    architecture = subprocess.check_output(["uname", "-m"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="yl-bridge-identity-") as temporary:
        def native_slice(path, name):
            data = path.read_bytes()
            # A one-architecture CocoaPods FAT wrapper still needs thinning.
            if data[:4].hex() not in {"cafebabe", "cafebabf", "bebafeca", "bfbafeca"}:
                return data
            thin = Path(temporary) / name
            run(["lipo", str(path), "-thin", architecture, "-output", str(thin)], ROOT, f"{platform}-{manager}-bridge-{name}")
            return thin.read_bytes()
        require(native_slice(original_bridge, "source") == native_slice(embedded_bridge, "embedded"), "Embedded bridge differs from the active package artifact")
    commands = run(["otool", "-l", str(executable)], ROOT, f"{platform}-{manager}-app-load-commands", capture=True)
    expected_path = "@executable_path/../Frameworks" if platform == "macos" else "@executable_path/Frameworks"
    require(expected_path in commands, "Built host lacks framework runtime search path")
    require(re.search(r"minos\s+" + ("12.0" if platform == "macos" else "15.0") + r"\b", commands), "Built host minimum OS differs from required floor")
    plugin_binaries = [frameworks / "yl_player_apple.framework/yl_player_apple"] if manager == "cocoapods" else list(executable.parent.glob("*.debug.dylib")) or [executable]
    require(all(path.is_file() for path in plugin_binaries), "Linked plugin binary missing")
    links = "\n".join(run(["otool", "-L", str(path)], ROOT, f"{platform}-{manager}-plugin-linkage", capture=True) for path in plugin_binaries)
    require("YlFFmpegBridge.framework/" in links, "Consumer plugin has no dynamic bridge linkage")
    require(engine + ".framework/" in links, "Consumer plugin has no real Flutter engine linkage")
    tests = list(contents.glob("PlugIns/RunnerTests.xctest"))
    require(not expect_tests or len(tests) == 1, "Built native test bundle is missing from the test host")
    for bundle in tests:
        binary = bundle / ("Contents/MacOS/RunnerTests" if platform == "macos" else "RunnerTests")
        loaded = run(["otool", "-l", str(binary)], ROOT, f"{platform}-{manager}-test-load-commands", capture=True)
        require(re.search(r"minos\s+" + ("12.0" if platform == "macos" else "15.0") + r"\b", loaded), "Built test bundle minimum OS differs")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["bootstrap", "check"])
    parser.add_argument("--platform", choices=["ios", "macos"])
    parser.add_argument("--manager", choices=["swiftpm", "cocoapods"])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--unit-only", action="store_true")
    mode.add_argument("--link", action="store_true")
    args = parser.parse_args()
    if args.action == "check":
        require(args.platform and args.manager and (args.unit_only or args.link), "check requires --platform, --manager and --unit-only|--link")
        check(args.platform, args.manager, args.link)
    else:
        for platform in [args.platform] if args.platform else ["macos", "ios"]:
            for manager in [args.manager] if args.manager else ["swiftpm", "cocoapods"]:
                bootstrap(platform, manager)
        print(f"Consumers: {OUTPUT}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
