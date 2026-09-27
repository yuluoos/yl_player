@testable import yl_player_apple
import Foundation
import XCTest

final class YlDashSidxTests: XCTestCase {
  private func word(_ value: UInt64, _ bytes: Int) -> [UInt8] {
    (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }
  private func box(version: UInt8 = 0, scale: UInt32 = 10, earliest: UInt64 = 7,
    firstOffset: UInt64 = 20, sizes: [UInt32] = [30, 40],
    durations: [UInt32] = [5, 15], sap: [UInt32] = [0x90000000, 0x20000003],
    extended: Bool = false) -> Data {
    var body = [version, 0, 0, 0] + word(1, 4) + word(UInt64(scale), 4)
    body += word(earliest, version == 0 ? 4 : 8)
    body += word(firstOffset, version == 0 ? 4 : 8)
    body += word(0, 2) + word(UInt64(sizes.count), 2)
    for index in sizes.indices {
      body += word(UInt64(sizes[index]), 4) + word(UInt64(durations[index]), 4) + word(UInt64(sap[index]), 4)
    }
    let size = UInt64(body.count + (extended ? 16 : 8))
    return Data(word(extended ? 1 : size, 4) + Array("sidx".utf8)
      + (extended ? word(size, 8) : []) + body)
  }
  private func parse(_ data: Data, end: UInt64 = 100, budget: Int = 8) throws -> YlDashSidxIndex {
    try YlDashSidx.parse(data, boxEndOffset: end, maxReferences: budget)
  }
  private func reject(_ data: Data, _ reason: YlDashSidxError = .invalidIndex,
    end: UInt64 = 100, budget: Int = 8, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try parse(data, end: end, budget: budget), file: file, line: line) {
      XCTAssertEqual($0 as? YlDashSidxError, reason, file: file, line: line)
    }
  }
  func testV0UsesAbsoluteEndAndPreservesTickUnitsAndSAP() throws {
    let index = try parse(box())
    XCTAssertEqual(index.referenceID, 1)
    XCTAssertEqual(index.timescale, 10)
    XCTAssertEqual(index.earliestPresentationTimeTicks, 7)
    XCTAssertEqual(index.references.map(\.offset), [120, 150])
    XCTAssertEqual(index.references.map(\.length), [30, 40])
    XCTAssertEqual(index.references.map(\.durationTicks), [5, 15])
    XCTAssertEqual(index.references.map(\.startsWithSAP), [true, false])
    XCTAssertEqual(index.references.map(\.sapType), [1, 2])
    XCTAssertEqual(index.references.map(\.sapDeltaTicks), [0, 3])
  }
  func testV1PreservesWideTimeAndOffsetWithoutRounding() throws {
    let index = try parse(box(version: 1, earliest: 4_294_967_299, firstOffset: 4_294_967_301), end: 5_000_000_000)
    XCTAssertEqual(index.earliestPresentationTimeTicks, 4_294_967_299)
    XCTAssertEqual(index.references.map(\.offset), [9_294_967_301, 9_294_967_331])
  }
  func testExplicitLargeSizeAndNonzeroDataStartIndex() throws {
    let bytes = box(extended: true)
    let prefixed = Data([0, 0, 0]) + bytes
    XCTAssertEqual(try parse(prefixed.dropFirst(3)).references.map(\.offset), [120, 150])
  }
  func testRejectsEveryTruncationAndUnrequestedTrailingBytes() {
    for extended in [false, true] {
      for version in [UInt8(0), 1] {
        let bytes = box(version: version, extended: extended)
        for length in 0..<bytes.count { reject(Data(bytes.prefix(length))) }
        reject(bytes + Data([0]))
        reject(bytes + box())
      }
    }
  }
  func testRejectsInvalidBoxAndZeroClockReferenceFields() {
    var wrongType = box(); wrongType[4] = 0
    reject(wrongType)
    var declaredSize = box(); declaredSize[3] = 8
    reject(declaredSize)
    var reserved = box(); reserved[28] = 1
    reject(reserved)
    reject(box(scale: 0))
    reject(box(sizes: [0, 40]))
    reject(box(durations: [0, 15]))
    reject(box(sizes: [], durations: [], sap: []))
    reject(box(), end: 1)
  }
  func testRejectsNestedIndexesAndUnsupportedBoxForms() {
    reject(box(sizes: [0x8000001E, 40]), .unsupportedIndex)
    var version = box(); version[8] = 2
    reject(version, .unsupportedIndex)
    var flags = box(); flags[11] = 1
    reject(flags, .unsupportedIndex)
    var unbounded = box(); unbounded.replaceSubrange(0..<4, with: [0, 0, 0, 0])
    reject(unbounded, .unsupportedIndex)
  }
  func testBudgetsRejectBeforeReferenceExpansion() {
    reject(box(), .limitExceeded, budget: 1)
    reject(box(), .limitExceeded, budget: 0)
    reject(box(), .limitExceeded, budget: -1)
    reject(Data(repeating: 0, count: 1_048_577), .limitExceeded)
    var missingEntries = box(); missingEntries[30] = 0xFF; missingEntries[31] = 0xFF
    reject(missingEntries, .limitExceeded)
    reject(missingEntries, .invalidIndex, budget: 65_535)
  }
  func testRejectsOverflowInOffsetEndAndCumulativeTime() {
    reject(box(version: 1, firstOffset: UInt64.max), end: 100)
    reject(box(version: 1, firstOffset: 0), end: UInt64.max - 50)
    reject(box(version: 1, earliest: UInt64.max - 10))
    // A representable exclusive end at UInt64.max remains lossless, not rounded.
    XCTAssertNoThrow(try parse(box(version: 1, earliest: UInt64.max - 20, firstOffset: 0), end: UInt64.max - 70))
  }
  func testSafeFailureMappingUsesExistingPublicCodes() {
    for reason in [YlDashSidxError.invalidIndex, .unsupportedIndex, .limitExceeded] {
      XCTAssertEqual(reason.nativeError.code, reason == .limitExceeded ? "resource.exhausted" : "container.unsupported")
      XCTAssertNil(reason.nativeError.diagnostic)
    }
  }
  func testOwnedSingleFileV0V1IndexesMatchActualFragmentBoundaries() throws {
    for version in 0...1 {
      let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "dash-sidx-v\(version)", withExtension: "mp4"))
      let file = try Data(contentsOf: url)
      let end = version == 0 ? 906 : 914
      let index = try parse(file.subdata(in: 826..<end), end: UInt64(end), budget: 4)
      XCTAssertEqual(index.timescale, 12288)
      XCTAssertEqual(index.earliestPresentationTimeTicks, 0)
      XCTAssertEqual(index.references.map(\.length), [13625, 23935, 31162, 33734])
      XCTAssertEqual(index.references.map(\.durationTicks), [12288, 12288, 12288, 12288])
      for reference in index.references {
        let start = Int(reference.offset)
        XCTAssertEqual(String(data: file.subdata(in: (start + 4)..<(start + 8)), encoding: .ascii), "styp")
      }
      let last = try XCTUnwrap(index.references.last)
      XCTAssertEqual(last.offset + last.length, UInt64(file.count))
    }
  }
}
