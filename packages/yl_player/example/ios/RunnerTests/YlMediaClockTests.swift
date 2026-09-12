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

  func testAudioEndHandsOffContinuouslyToTheVideoTail() {
    var rendered: YlRenderedAudioTime? = .init(sampleTime: 0, sampleRate: 1_000_000)
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 0, sampleTime: 0)
    clock.play(atHostTimeUs: 0)
    rendered = .init(sampleTime: 5_000_000, sampleRate: 1_000_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 20_000_000), 5_000_000)

    rendered = nil
    XCTAssertEqual(clock.position(atHostTimeUs: 20_500_000), 5_500_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 21_000_000), 6_000_000)
  }

  func testAudioEndUsesPlaybackRateAndCanReturnToNormalDuringVideoTail() {
    var rendered: YlRenderedAudioTime? = .init(sampleTime: 0, sampleRate: 1_000_000)
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 0, sampleTime: 0)
    clock.play(atHostTimeUs: 0)
    clock.setRate(3, atHostTimeUs: 0)
    rendered = .init(sampleTime: 5_000_000, sampleRate: 1_000_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 4_000_000), 5_000_000)

    rendered = nil
    XCTAssertEqual(clock.position(atHostTimeUs: 4_250_000), 5_750_000)
    clock.setRate(1, atHostTimeUs: 4_250_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 4_500_000), 6_000_000)
  }

  func testAudioRecoveryContinuesFromTheHostPositionWithoutJumpingBack() {
    var rendered: YlRenderedAudioTime? = .init(sampleTime: 0, sampleRate: 1_000_000)
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 0, sampleTime: 0)
    clock.play(atHostTimeUs: 0)
    rendered = .init(sampleTime: 5_000_000, sampleRate: 1_000_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 20_000_000), 5_000_000)
    rendered = nil
    XCTAssertEqual(clock.position(atHostTimeUs: 21_000_000), 6_000_000)

    rendered = .init(sampleTime: 5_100_000, sampleRate: 1_000_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 21_250_000), 6_250_000)
    rendered = .init(sampleTime: 5_350_000, sampleRate: 1_000_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 21_500_000), 6_500_000)
    rendered = nil
    XCTAssertEqual(clock.position(atHostTimeUs: 22_000_000), 7_000_000)
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
