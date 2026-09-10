#!/usr/bin/env python3
"""Reject legacy or transport-specific Dart API exposed by v0.2 packages."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


LEGACY_SYMBOLS = (
    "YlPlayerConfiguration",
    "YlBufferMode",
    "YlFormatHint",
    "YlPlayerError",
    "YlTracksChangedEvent",
    "YlFallbackEvent",
    "isHardwareDecoding",
    "platformDiagnostic",
)
CHANNEL_SYMBOLS = (
    "MethodChannel",
    "EventChannel",
    "BasicMessageChannel",
    "PlatformException",
    "FlutterError",
)
PLATFORM_INTERFACE_URI = (
    "package:yl_player_platform_interface/yl_player_platform_interface.dart"
)


@dataclass(frozen=True)
class Violation:
    path: Path
    line: int
    message: str


def _mask_comments(source: str) -> str:
    """Mask Dart comments while preserving strings, positions, and newlines."""
    chars = list(source)
    i = 0
    quote: str | None = None
    triple = False
    while i < len(chars):
        if quote is not None:
            width = 3 if triple else 1
            if source.startswith(quote * width, i):
                i += width
                quote = None
                triple = False
                continue
            if source[i] == "\\" and not triple:
                i += 2
            else:
                i += 1
            continue
        if source.startswith("//", i):
            end = source.find("\n", i)
            if end < 0:
                end = len(chars)
            for j in range(i, end):
                chars[j] = " "
            i = end
            continue
        if source.startswith("/*", i):
            end = source.find("*/", i + 2)
            end = len(chars) if end < 0 else end + 2
            for j in range(i, end):
                if chars[j] != "\n":
                    chars[j] = " "
            i = end
            continue
        if source[i] in ("'", '"'):
            quote = source[i]
            triple = source.startswith(quote * 3, i)
            i += 3 if triple else 1
            continue
        i += 1
    return "".join(chars)


def _mask_non_code(source: str) -> str:
    """Mask comments and string literals for identifier-only searches."""
    source = _mask_comments(source)
    chars = list(source)
    i = 0
    while i < len(chars):
        if source[i] not in ("'", '"'):
            i += 1
            continue
        quote = source[i]
        width = 3 if source.startswith(quote * 3, i) else 1
        end_token = quote * width
        end = i + width
        while end < len(chars):
            if source.startswith(end_token, end):
                end += width
                break
            if source[end] == "\\" and width == 1:
                end += 2
            else:
                end += 1
        for j in range(i, min(end, len(chars))):
            if chars[j] != "\n":
                chars[j] = " "
        i = end
    return "".join(chars)


_DIRECTIVE = re.compile(
    r"(?P<kind>import|export)\s+(?P<quote>['\"])(?P<uri>[^'\"]+)"
    r"(?P=quote)(?P<tail>.*?);",
    re.DOTALL,
)


def _line(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def _is_generated_pigeon_uri(uri: str) -> bool:
    normalized = uri.lower().replace("\\", "/")
    parts = normalized.split("/")
    basename = parts[-1]
    return "pigeon" in parts or basename.endswith(".g.dart")


def _directive_uris(match: re.Match[str]) -> list[str]:
    uris = [match.group("uri")]
    uris.extend(
        quoted.group("uri")
        for quoted in re.finditer(
            r"(?P<quote>['\"])(?P<uri>[^'\"]+)(?P=quote)",
            match.group("tail"),
        )
    )
    return uris


def _directives(source: str, code: str):
    """Yield real directives, excluding directive-like text in comments/strings."""
    for start in re.finditer(r"\b(?:import|export)\b", code):
        end = code.find(";", start.start())
        if end < 0:
            continue
        match = _DIRECTIVE.fullmatch(_mask_comments(source[start.start() : end + 1]))
        if match:
            yield start.start(), match


def validate(repo_root: Path) -> list[Violation]:
    roots = {
        "platform interface": repo_root
        / "packages/yl_player_platform_interface/lib",
        "application": repo_root / "packages/yl_player/lib",
    }
    violations: list[Violation] = []
    for boundary, source_root in roots.items():
        if not source_root.is_dir():
            violations.append(Violation(source_root, 1, "production source root is missing"))
            continue
        for path in sorted(source_root.rglob("*.dart")):
            source = path.read_text(encoding="utf-8")
            code = _mask_non_code(source)
            for symbol in LEGACY_SYMBOLS:
                match = re.search(rf"\b{re.escape(symbol)}\b", code)
                if match:
                    violations.append(
                        Violation(path, _line(source, match.start()), f"legacy symbol {symbol}")
                    )
            if boundary == "platform interface":
                for symbol in CHANNEL_SYMBOLS:
                    match = re.search(rf"\b{re.escape(symbol)}\b", code)
                    if match:
                        violations.append(
                            Violation(
                                path,
                                _line(source, match.start()),
                                f"Flutter channel symbol {symbol}",
                            )
                        )

            for offset, match in _directives(source, code):
                kind = match.group("kind")
                uris = _directive_uris(match)
                for uri in uris:
                    if _is_generated_pigeon_uri(uri):
                        violations.append(
                            Violation(
                                path,
                                _line(source, offset),
                                f"{kind} of generated Pigeon library {uri}",
                            )
                        )
                if (
                    boundary == "application"
                    and kind == "export"
                    and PLATFORM_INTERFACE_URI in uris
                    and not re.search(r"\bshow\b", _mask_non_code(match.group("tail")))
                ):
                    violations.append(
                        Violation(
                            path,
                            _line(source, offset),
                            "platform-interface export requires an explicit show combinator",
                        )
                    )
    return violations


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    violations = validate(root)
    if violations:
        print("public surface check failed:")
        for violation in violations:
            try:
                path = violation.path.relative_to(root)
            except ValueError:
                path = violation.path
            print(f"  {path}:{violation.line}: {violation.message}")
        return 1
    print("public surface check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
