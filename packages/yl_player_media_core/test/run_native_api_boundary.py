#!/usr/bin/env python3
"""Check public API visibility against real core, delivery and Apple modules."""
from pathlib import Path
import argparse
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tool.media_delivery.native_build import build_modules


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="yl-core-api-") as temporary:
        output = args.build_dir or Path(temporary)
        build = build_modules(output, include_apple=True)
        positive = build.compile_test(
            [Path(__file__).with_name("native_module_boundary.swift")],
            output / "public-input-contracts",
        )
        subprocess.run([str(positive)], check=True)

        # Each probe must compile under @testable before ordinary import is
        # rejected: unrelated syntax or dependency failures cannot pass this gate.
        hidden = (
            "YlRtmpMessage", "YlRtmpChunkReader", "YlRtmpAmf",
            "YlRtmpFlowControl", "YlRtmpFlvStream", "ylRtmpLimit",
            "YlHTTPResponseParser", "YlByteRingBuffer",
        )
        leaked = []
        for symbol in hidden:
            probe = output / "visibility-probe.swift"
            expression = symbol if symbol == "ylRtmpLimit" else f"{symbol}.self"
            body = f"import Foundation\nlet implementation = {expression}\n"
            probe.write_text("@testable import yl_player_media_core\n" + body)
            command = ["xcrun", "swiftc", *build.flags, "-typecheck", str(probe)]
            subprocess.run(command, check=True, capture_output=True, text=True)
            probe.write_text("import yl_player_media_core\n" + body)
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode == 0:
                leaked.append(symbol)
            elif f"cannot find '{symbol}' in scope" not in result.stderr:
                raise RuntimeError(f"Unexpected {symbol} probe failure:\n{result.stderr}")
        if leaked:
            raise AssertionError("Internal implementation leaks through ordinary import: "
                                 + ", ".join(leaked))
        print(f"PASS ordinary import hides {len(hidden)} implementation symbols")

        # Execute the existing protocol regression suite unchanged, with access
        # to core internals explicitly requested by the test module.
        tests = ROOT / "tool/consumer_fixtures/apple_flutter/RunnerTests/YlRtmpProtocolTests.swift"
        methods = re.findall(r"^\s+func (test\w+)\(", tests.read_text(), re.MULTILINE)
        if not methods:
            raise RuntimeError("No RTMP protocol regression tests were discovered")
        driver = output / "main.swift"
        driver.write_text(
            "import XCTest\n"
            "let suite = XCTestSuite(forTestCaseClass: YlRtmpProtocolTests.self)\n"
            "suite.run()\n"
            f"guard let result = suite.testRun, result.executionCount == {len(methods)},\n"
            "      result.totalFailureCount == 0 else {\n"
            '  fatalError("RTMP protocol regression suite failed or omitted tests")\n'
            "}\n"
        )
        platform_path = Path(subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True
        ).strip())
        xctest = platform_path / "Developer/Library/Frameworks"
        xctest_swift = platform_path / "Developer/usr/lib"
        build.flags += ["-F", str(xctest), "-I", str(xctest_swift),
                        "-L", str(xctest_swift), "-framework", "XCTest",
                        "-Xlinker", "-rpath", "-Xlinker", str(xctest),
                        "-Xlinker", "-rpath", "-Xlinker", str(xctest_swift)]
        binary = build.compile_test(
            [tests, driver], output / "rtmp-protocol-tests",
            imports=["@testable import yl_player_media_core"],
        )
        subprocess.run([str(binary)], check=True)
        print("PASS public input contracts and existing @testable RTMP regressions")


if __name__ == "__main__":
    main()
