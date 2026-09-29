import Foundation

@main
struct HEVCRandomAccessTests {
  static var checks = 0
  static func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError(message) }
  }
  static func packet(_ types: [UInt8], width: Int = 4) -> [UInt8] {
    types.flatMap { type in
      Array(repeating: UInt8(0), count: width - 1) + [2, type << 1, 1]
    }
  }
  static func accept(_ gate: inout YlHEVCRandomAccessGate, _ types: [UInt8], width: Int = 4) -> Bool {
    packet(types, width: width).withUnsafeBytes { !gate.shouldDiscard($0, nalLengthBytes: width) }
  }
  static func main() {
    for width in [1, 2, 4] {
      var gate = YlHEVCRandomAccessGate()
      check(accept(&gate, [32, 33, 34, 39], width: width), "metadata must not start a picture sequence")
      check(accept(&gate, [21, 21], width: width), "CRA and its slices must decode")
      check(!accept(&gate, [9], width: width), "random-access RASL_R must be discarded")
      check(!accept(&gate, [8], width: width), "random-access RASL_N must be discarded")
      check(accept(&gate, [6], width: width), "decodable RADL must be retained")
      check(accept(&gate, [1], width: width), "trailing reference frame must decode")
      check(accept(&gate, [21], width: width), "later continuous CRA must decode")
      check(accept(&gate, [8, 8], width: width), "continuous RASL must not be discarded")
      check(accept(&gate, [16], width: width), "BLA must decode")
      check(!accept(&gate, [9], width: width), "BLA RASL cannot use old references")
      var reset = YlHEVCRandomAccessGate()
      check(accept(&reset, [21], width: width), "new decoder sequence must reset")
      check(!accept(&reset, [8], width: width), "new sequence must discard leading RASL")
    }
    var gate = YlHEVCRandomAccessGate()
    check(accept(&gate, [19]), "IDR must decode")
    check(accept(&gate, [7]), "IDR RADL must decode")
    check(accept(&gate, [21]), "continuous CRA after IDR must decode")
    check(accept(&gate, [9]), "continuous GOP must preserve RASL")
    var malformed = YlHEVCRandomAccessGate()
    let invalid: [[UInt8]] = [[], [0,0,0], [0,0,0,0], [0,0,0,1,42],
      [255,255,255,255,42,1], [0,0,0,2,42,0], [0,0,0,2,170,1],
      packet([21]) + [0], packet([21,8]), [0,0,0,2,42,9]]
    for bytes in invalid {
      check(bytes.withUnsafeBytes { !malformed.shouldDiscard($0, nalLengthBytes: 4) },
        "malformed/multilayer access unit must reach existing decoder validation")
    }
    check(accept(&malformed, [21]), "invalid input must not consume initial CRA state")
    check(!accept(&malformed, [8]), "initial CRA gate must survive invalid input")
    let badRasl = packet([8]) + [0]
    check(badRasl.withUnsafeBytes { !malformed.shouldDiscard($0, nalLengthBytes: 4) },
      "malformed RASL must not be silently discarded")
    for width in [0,3,5] {
      check(packet([8]).withUnsafeBytes { !malformed.shouldDiscard($0, nalLengthBytes: width) },
        "unsupported length field must not be accepted")
    }
    print("HEVC random access: \(checks) checks passed")
  }
}
