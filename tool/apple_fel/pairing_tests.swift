import Foundation

@main struct FELPairingTests {
  static func main() throws {
    let pairs = YlFELPairing<String, Int>(capacity: 2)
    pairs.reset(generation: 10)
    try pairs.register(pts: 200, generation: 10, metadata: 2)
    try pairs.register(pts: 100, generation: 10, metadata: 1)
    try check(try pairs.receive("el100", side: .enhancement, pts: 100, generation: 10) == nil)
    try check(try pairs.receive("bl200", side: .base, pts: 200, generation: 10) == nil)
    let first = try pairs.receive("bl100", side: .base, pts: 100, generation: 10)
    try check(first?.base == "bl100" && first?.enhancement == "el100" && first?.metadata == 1)
    let second = try pairs.receive("el200", side: .enhancement, pts: 200, generation: 10)
    try check(second?.metadata == 2)
    try pairs.finish(generation: 10)

    try pairs.register(pts: 300, generation: 10, metadata: 3)
    try expectFailure { try pairs.register(pts: 300, generation: 10, metadata: 4) }
    _ = try pairs.receive("base", side: .base, pts: 300, generation: 10)
    try expectFailure { _ = try pairs.receive("duplicate", side: .base, pts: 300, generation: 10) }
    try expectFailure { try pairs.finish(generation: 10) }
    pairs.reset(generation: 11)
    try check(try pairs.receive("stale", side: .enhancement, pts: 300, generation: 10) == nil)
    try pairs.register(pts: 300, generation: 11, metadata: 30)
    try check(try pairs.receive("fresh", side: .enhancement, pts: 300, generation: 11) == nil)
    let fresh = try pairs.receive("freshBL", side: .base, pts: 300, generation: 11)
    try check(fresh?.metadata == 30 && fresh?.enhancement == "fresh")
    try expectFailure { _ = try pairs.receive("orphan", side: .base, pts: 999, generation: 11) }
    try expectFailure { try pairs.register(pts: Int64.min, generation: 11, metadata: 0) }
    try pairs.register(pts: 1, generation: 11, metadata: 1)
    try pairs.register(pts: 2, generation: 11, metadata: 2)
    try expectFailure { try pairs.register(pts: 3, generation: 11, metadata: 3) }
    pairs.reset(generation: 12)
    try pairs.finish(generation: 12)
    print("FEL pairing: reorder, duplicate, missing, stale epoch, unknown PTS and capacity passed")
  }

  static func check(_ body: @autoclosure () throws -> Bool) throws {
    let value = try body()
    precondition(value)
  }

  static func expectFailure(_ body: () throws -> Void) throws {
    do { try body(); fatalError("Expected strict FEL pairing failure") }
    catch is YlFELPairingError {}
  }
}
