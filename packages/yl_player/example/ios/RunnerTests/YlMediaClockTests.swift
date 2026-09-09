@testable import yl_player_apple
import XCTest

final class YlMediaClockTests: XCTestCase {
  func testVideoOnlyClockTracksRatePauseAndSeek() {
    let clock = YlMediaClock()
    clock.seek(to: 2_000_000)
    clock.play(atHostTimeUs: 10_000_000)

    clock.setRate(0.25, atHostTimeUs: 11_000_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 12_000_000), 3_250_000)

    clock.setRate(4, atHostTimeUs: 12_000_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 12_500_000), 5_250_000)

    clock.pause(atHostTimeUs: 12_500_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 99_000_000), 5_250_000)

    clock.seek(to: 750_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 100_000_000), 750_000)
  }

  func testRenderedAudioSampleTimeIsMasterClock() {
    var rendered = YlRenderedAudioTime(sampleTime: 48_000, sampleRate: 48_000)
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 3_000_000, sampleTime: 48_000)
    clock.play(atHostTimeUs: 0)

    rendered = YlRenderedAudioTime(sampleTime: 72_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 900_000_000), 3_500_000)

    clock.pause(atHostTimeUs: 900_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 96_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 901_000_000), 3_500_000)
  }
}
