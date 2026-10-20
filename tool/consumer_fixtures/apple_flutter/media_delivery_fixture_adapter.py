"""Adapt immutable pre-split characterization sources in generated consumers.

Historical fixture hashes remain meaningful. The actual generated tests import
the separate core/delivery modules and opt into delivery only where exercised.
"""
from pathlib import Path
import re


def native_test_source(path: Path) -> bytes:
    text = path.read_text()
    prefix = "@testable import yl_player_media_core\n"
    if path.name in {"AppleHostCharacterizations.swift", "YlAppleHostTests.swift", "YlRtmpTransportTests.swift"}:
        prefix += "@testable import yl_player_media_delivery\n"
    if path.name == "YlRtmpTransportTests.swift":
        text, count = re.subn(
            r"YlAirPlayLiveRemux\.prepare\(source: source,\s*configuration: PlayerConfiguration\(map: \[:\]\),",
            "YlAirPlayLiveRemux.prepare(input: try YlAppleDeliveryInput.make(source: source, "
            "configuration: PlayerConfiguration(map: [:]), live: true),",
            text,
        )
        if count != 3:
            raise RuntimeError("RTMP delivery fixture adaptation no longer matches three call sites")
    if path.name == "AppleHostCharacterizations.swift":
        text = text.replace(
            "audioOwnership: YlPlayerAudioOwnership? = nil) {",
            "audioOwnership: YlPlayerAudioOwnership? = nil, deliveryEnabled: Bool = false) {",
        )
        text = text.replace(
            "    host = YlApplePlayerHost(playerId: 91,",
            "    var services = YlPlatformServices(platform: .current, textureOutput: output,\n"
            "      makeDisplayDriver: { AppleClockDisplay(onTick: $0) })\n"
            "    if deliveryEnabled { services.mediaDeliveryService = { YlMediaDeliveryEngine() } }\n"
            "    host = YlApplePlayerHost(playerId: 91,",
        )
        text = text.replace(
            "services: .init(platform: .current, textureOutput: output,\n"
            "        makeDisplayDriver: { AppleClockDisplay(onTick: $0) }), callbacks:",
            "services: services, callbacks:",
        )
    if path.name == "YlAppleHostTests.swift":
        enabled = {
            "testReplacingAirPlayWithFallbackReleasesRetiredOrigin",
            "testNetworkCustomSourceLoadsThroughAirPlayRemuxAndReleasesOriginOnStop",
            "testHttpFlvAirPlayBecomesReadyBeforeEOFAndRollsUntilStop",
            "testHttpFlvAirPlayReconnectPublishesDiscontinuityAndNewMap",
            "testAutomaticRtmpAirPlayBecomesReadyWithoutUpstreamEOF",
            "testStoppingHeldRtmpAirPlayStartupCancelsPromptly",
            "testAutomaticRtmpsLoadAndAirPlayReachTlsAndRejectUntrustedPeer",
        }
        current = None
        lines = []
        for line in text.splitlines(keepends=True):
            match = re.search(r"\bfunc (test\w+)\(", line)
            if match:
                current = match.group(1)
            if current in enabled:
                line = line.replace("AppleHostFixture()", "AppleHostFixture(deliveryEnabled: true)")
                line = line.replace(
                    "AppleHostFixture(videoSessionFactory: AirPlayPassiveVTFactory())",
                    "AppleHostFixture(videoSessionFactory: AirPlayPassiveVTFactory(), deliveryEnabled: true)",
                )
            lines.append(line)
            if current == "testNetworkCustomSourceLoadsThroughAirPlayRemuxAndReleasesOriginOnStop" and "let server = try ReactivationMediaServer" in line:
                lines.append(
                    "    let absent = AppleHostFixture(); defer { absent.host.close() }\n"
                    "    do {\n"
                    "      _ = try await absent.host.loadAirPlay(request: AppleHostFixture.request(\"absent-delivery\", url: server.url.absoluteString, format: .matroska))\n"
                    "      XCTFail(\"Custom AirPlay requires the optional delivery service\")\n"
                    "    } catch { XCTAssertEqual((error as? PigeonError)?.code, \"airplay.delivery_unavailable\") }\n"
                    "    XCTAssertNil(absent.host.sessionId)\n"
                )
        text = "".join(lines)
    return (prefix + text).encode()
