@testable import yl_player_media_core
@testable import yl_player_apple
import Foundation
import XCTest

final class YlProgramStreamTests: XCTestCase {
  // MPEG-1 and MPEG-2 pack headers with all mandatory marker bits present.
  private let mpeg1: [UInt8] = [0,0,1,0xba,0x21,0,1,0,1,0x80,0,1]
  private let mpeg2: [UInt8] = [0,0,1,0xba,0x44,0,4,0,4,1,0,0,3,0xf8]

  func testCompletePackHeadersAndStuffingAreRecognized() {
    XCTAssertEqual(YlSourceInspector.format(Data(mpeg1)), .mpegPs)
    XCTAssertEqual(YlSourceInspector.format(Data(mpeg2)), .mpegPs)
    var stuffed = mpeg2; stuffed[13] |= 7; stuffed += Array(repeating: 0xff, count: 7)
    XCTAssertEqual(YlSourceInspector.format(Data(stuffed)), .mpegPs)
    stuffed[20] = 0
    XCTAssertEqual(YlSourceInspector.format(Data(stuffed)), .automatic)
  }
  func testTruncatedAndInvalidPackHeadersCannotCommitARoute() {
    for header in [mpeg1, mpeg2] {
      for size in 0..<header.count {
        XCTAssertEqual(YlSourceInspector.format(Data(header.prefix(size))), .automatic)
      }
    }
    for (index, mask): (Int, UInt8) in [(4,4),(6,4),(8,4),(9,1),(12,1),(12,2),(13,8)] {
      var invalid = mpeg2; invalid[index] ^= mask
      XCTAssertEqual(YlSourceInspector.format(Data(invalid)), .automatic)
    }
    for index in [4,6,8,11] {
      var invalid = mpeg1; invalid[index] ^= 1
      XCTAssertEqual(YlSourceInspector.format(Data(invalid)), .automatic)
    }
    var shortStuffing = mpeg2; shortStuffing[13] |= 7
    XCTAssertEqual(YlSourceInspector.format(Data(shortStuffing + [0xff])), .automatic)
  }
  func testProgramStreamSelectsOwnedFallbackWithManagedPolicy() {
    var source = YlAppleSourceDescriptor(uri: "file:///owned.mpg", kind: .file, formatHint: .mpegPs)
    let ordinary = YlEngineRouter.assess(source)
    XCTAssertEqual(ordinary.outcome, .requiresInspection)
    XCTAssertEqual(ordinary.engine, .managedFallback)
    source.networkPolicy = .managed
    XCTAssertEqual(YlEngineRouter.assess(source).outcome, .requiresInspection)
    source.networkPolicy = .platformDefault; source.intent = .live
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "container.mpegps_live_unsupported")
  }
  func testAutomaticKnownExtensionsRequireContentBeforeContainerCommit() throws {
    for ext in ["mp4", "mov", "mkv", "webm", "avi", "ts", "mpg", "flv", "bin"] {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
      try Data(mpeg2).write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }
      let source = YlAppleSourceDescriptor(uri: url.absoluteString, kind: .file)
      XCTAssertEqual(YlEngineRouter.assess(source).candidate, .inspect)
      let inspected = try YlSourceInspector.inspect(source, configuration: .init(map: [:]), token: .init())
      XCTAssertEqual(inspected.formatHint, .mpegPs)
      XCTAssertEqual(YlEngineRouter.assess(inspected).engine, .managedFallback)
    }
  }

  func testOlderOSUsesOwnedSamplesWhenMP4MIMEHintCannotBeHonored() {
    for name in ["video.bin", "video.mkv", "video"] {
      let source = YlAppleSourceDescriptor(uri: "file:///" + name, kind: .file, formatHint: .mp4)
      XCTAssertTrue(YlMp4CompatibilityInspector.needsOwnedMIMEFallback(source, supportsMIMEOverride: false))
      XCTAssertFalse(YlMp4CompatibilityInspector.needsOwnedMIMEFallback(source, supportsMIMEOverride: true))
    }
    for name in ["movie.bin", "movie.mkv", "movie.mp4", "movie"] {
      let source = YlAppleSourceDescriptor(uri: "file:///" + name, kind: .file, formatHint: .mov)
      XCTAssertTrue(YlMp4CompatibilityInspector.needsOwnedMIMEFallback(source, supportsMIMEOverride: false))
      XCTAssertFalse(YlMp4CompatibilityInspector.needsOwnedMIMEFallback(source, supportsMIMEOverride: true))
    }
    let named = YlAppleSourceDescriptor(uri: "file:///video.mp4", kind: .file, formatHint: .mp4)
    XCTAssertFalse(YlMp4CompatibilityInspector.needsOwnedMIMEFallback(named, supportsMIMEOverride: false))
  }

  func testLegacyQuickTimeAtomLayoutWithoutFtyp() {
    func atom(_ name: String, _ payload: [UInt8] = []) -> [UInt8] {
      let size = UInt32(8 + payload.count)
      return [UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)] + Array(name.utf8) + payload
    }
    XCTAssertEqual(YlSourceInspector.format(Data(atom("free", [0,0,0,0]) + atom("wide") + atom("mdat", [1,2,3,4]))), .mov)
    XCTAssertEqual(YlSourceInspector.format(Data(atom("moov", atom("mvhd")))), .mov)
    XCTAssertEqual(YlSourceInspector.format(Data(atom("free"))), .automatic)
    XCTAssertEqual(YlSourceInspector.format(Data([0,0,0,4] + Array("mdat".utf8))), .automatic)
    XCTAssertEqual(YlSourceInspector.format(Data(atom("free") + atom("ftyp", Array("isom".utf8)))), .mp4)
  }

}
