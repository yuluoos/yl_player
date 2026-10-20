"""Build the real Apple native modules for host-only Swift acceptance checks."""
from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "packages/yl_player_media_core/darwin/yl_player_media_core"
BRIDGE = CORE / "Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64"


def flutter_framework() -> Path:
    configured = os.environ.get("FLUTTER_ROOT")
    executable = shutil.which("flutter")
    sdk = Path(configured) if configured else (
        Path(executable).resolve().parents[1] if executable else Path.home() / "flutter"
    )
    return sdk / "bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"


@dataclass
class NativeBuild:
    output: Path
    flags: list[str]
    modules: tuple[str, ...]

    def compile_test(
        self, sources: list[Path], output: Path, imports: list[str] | None = None
    ) -> Path:
        """Prefix imports on scratch copies; never alter the checked-in tests."""
        output = output.resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="test-sources-", dir=self.output) as temp:
            copies = []
            uses_main_attribute = False
            prefix = "".join(
                (name if name.startswith(("import ", "@testable import ")) else f"@testable import {name}") + "\n"
                for name in (imports or [])
            )
            for index, source in enumerate(sources):
                text = source.read_text()
                uses_main_attribute |= "@main" in text
                copy = Path(temp) / str(index) / source.name
                copy.parent.mkdir()
                copy.write_text(prefix + text)
                copies.append(str(copy))
            subprocess.run(
                ["xcrun", "swiftc", *self.flags,
                 *(["-parse-as-library"] if uses_main_attribute else []),
                 *copies, "-o", str(output)],
                check=True,
            )
        return output


def build_modules(
    output: Path, include_apple: bool = False, include_delivery: bool = True
) -> NativeBuild:
    """Compile core, optional delivery and optional Apple as separate dylibs."""
    if platform.system() != "Darwin":
        raise RuntimeError("Native module checks require macOS/Xcode")
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    flutter = flutter_framework()
    for directory, name in ((flutter, "FlutterMacOS"), (BRIDGE, "YlFFmpegBridge")):
        if not (directory / f"{name}.framework").is_dir():
            raise FileNotFoundError(f"Required framework is unavailable: {directory / name}")
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    common = [
        "-swift-version", "5", "-target", f"{platform.machine()}-apple-macos12.0",
        "-sdk", sdk, "-module-cache-path", str(output / "module-cache"),
        "-I", str(output), "-L", str(output),
        "-Xlinker", "-rpath", "-Xlinker", str(output),
    ]
    for directory, name in ((flutter, "FlutterMacOS"), (BRIDGE, "YlFFmpegBridge")):
        common += ["-F", str(directory), "-framework", name,
                   "-Xlinker", "-rpath", "-Xlinker", str(directory)]
    modules = ["yl_player_media_core"]
    if include_delivery:
        modules.append("yl_player_media_delivery")
    if include_apple:
        modules.append("yl_player_apple")
    # Snapshot every module before compilation, so edits made while swiftc runs
    # cannot change a single module's inputs between its compile phases.
    with tempfile.TemporaryDirectory(prefix="module-sources-", dir=output) as temp:
        snapshots: dict[str, list[str]] = {}
        for module in modules:
            source_root = ROOT / f"packages/{module}/darwin/{module}/Sources/{module}"
            files = sorted(source_root.rglob("*.swift"))
            if not files:
                raise FileNotFoundError(f"No Swift sources found: {source_root}")
            snapshots[module] = []
            for source in files:
                copy = Path(temp) / module / source.relative_to(source_root)
                copy.parent.mkdir(parents=True, exist_ok=True)
                copy.write_bytes(source.read_bytes())
                snapshots[module].append(str(copy))
        for module in modules:
            dependencies = [] if module == "yl_player_media_core" else ["-lyl_player_media_core"]
            subprocess.run(
                ["xcrun", "swiftc", *common, *dependencies,
                 "-emit-library", "-emit-module", "-enable-testing",
                 "-module-name", module,
                 "-emit-module-path", str(output / f"{module}.swiftmodule"),
                 "-Xlinker", "-install_name", "-Xlinker", f"@rpath/lib{module}.dylib",
                 *snapshots[module], "-o", str(output / f"lib{module}.dylib")],
                check=True,
            )
    return NativeBuild(output, common + [f"-l{module}" for module in modules], tuple(modules))
