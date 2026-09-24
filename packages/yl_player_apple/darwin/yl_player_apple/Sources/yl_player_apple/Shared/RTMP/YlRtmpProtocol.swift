import Foundation

struct YlRtmpMessage {
  let type: Int
  let stream: UInt32
  let timestamp: UInt32
  let payload: Data
}

extension Data {
  mutating func rtmpBE(_ value: UInt64, _ count: Int) {
    for shift in (0..<count).reversed() { append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
  }
  func rtmpUInt(_ offset: Int, _ count: Int) -> UInt64 {
    self[offset..<offset+count].reduce(0) { ($0 << 8) | UInt64($1) }
  }
}

/// Reader-local state is retained even when an AVIO consumer temporarily interrupts.
final class YlRtmpChunkReader {
  private final class State {
    var timestamp: UInt32 = 0, delta: UInt32 = 0, extendedValue: UInt32 = 0
    var length = 0, type = 0, stream: UInt32 = 0
    var extended = false
    var payload: Data?
  }
  private let read: (Int) throws -> Data
  private var states: [Int: State] = [:]
  private var chunkSize = 128
  private(set) var allocatedBytes = 0
  init(read: @escaping (Int) throws -> Data) { self.read = read }
  private func uint(_ count: Int) throws -> UInt32 {
    let bytes = try read(count)
    guard bytes.count == count else { throw ylRtmpInvalid() }
    return UInt32(bytes.rtmpUInt(0, count))
  }
  func setChunkSize(_ value: UInt32) throws {
    guard value > 0 && value <= 65536 else { throw ylRtmpLimit() }; chunkSize = Int(value)
  }
  func abort(_ id: Int) {
    if let state = states[id], state.payload != nil { allocatedBytes -= state.length; state.payload = nil }
  }
  func next() throws -> YlRtmpMessage {
    while true {
      let basic = try uint(1), fmt = basic >> 6
      var cs = Int(basic & 63)
      if cs == 0 { cs = 64 + Int(try uint(1)) }
      else if cs == 1 { let low = try uint(1); cs = 64 + Int(low) + Int(try uint(1)) * 256 }
      let state: State
      if let previous = states[cs] { state = previous }
      else {
        guard fmt == 0 else { throw ylRtmpInvalid() }
        guard states.count < 32 else { throw ylRtmpLimit() }
        state = State(); states[cs] = state
      }
      let continuation = state.payload != nil
      guard !continuation || fmt == 3 else { throw ylRtmpInvalid() }
      if fmt != 3 {
        let stamp = try uint(3)
        if fmt < 2 { state.length = Int(try uint(3)); state.type = Int(try uint(1)) }
        if fmt == 0 {
          let little = try read(4)
          state.stream = little.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
          guard state.stream <= Int32.max else { throw ylRtmpInvalid() }
        }
        state.extended = stamp == 0xffffff
        let full = try state.extended ? uint(4) : stamp
        state.extendedValue = full; state.delta = full
        state.timestamp = fmt == 0 ? full : state.timestamp &+ full
      } else {
        if state.extended, try uint(4) != state.extendedValue { throw ylRtmpInvalid() }
        if !continuation { state.timestamp &+= state.delta }
      }
      if !continuation {
        guard [1,2,3,4,5,6,8,9,18,20].contains(state.type) else { throw ylRtmpInvalid() }
        let limit = [8,9].contains(state.type) ? 4 * 1024 * 1024 : 65536
        guard state.length <= limit, allocatedBytes + state.length <= 8 * 1024 * 1024 else { throw ylRtmpLimit() }
        state.payload = Data(); state.payload!.reserveCapacity(state.length); allocatedBytes += state.length
      }
      let n = min(chunkSize, state.length - state.payload!.count)
      state.payload!.append(try read(n))
      if state.payload!.count == state.length {
        let result = YlRtmpMessage(type: state.type, stream: state.stream, timestamp: state.timestamp, payload: state.payload!)
        allocatedBytes -= state.length; state.payload = nil; return result
      }
    }
  }
}

enum YlRtmpAmf {
  static func decode(_ bytes: Data) throws -> [Any] {
    guard bytes.count <= 65536 else { throw ylRtmpLimit() }
    var at = 0, entries = 0
    func uint(_ count: Int) throws -> UInt64 {
      guard count <= bytes.count - at else { throw ylRtmpInvalid() }
      defer { at += count }; return bytes.rtmpUInt(at, count)
    }
    func string(_ count: Int) throws -> String {
      guard count <= 16384 else { throw ylRtmpLimit() }
      guard count <= bytes.count - at, let value = String(data: bytes.subdata(in: at..<at+count), encoding: .utf8) else { throw ylRtmpInvalid() }
      at += count; return value
    }
    func value(_ depth: Int) throws -> Any {
      entries += 1
      guard depth <= 8 && entries <= 256 else { throw ylRtmpLimit() }
      let marker = try uint(1)
      switch marker {
      case 0:
        let number = Double(bitPattern: try uint(8)); guard number.isFinite else { throw ylRtmpInvalid() }; return number
      case 1:
        let bool = try uint(1); guard bool < 2 else { throw ylRtmpInvalid() }; return bool == 1
      case 2: return try string(Int(uint(2)))
      case 3,8:
        if marker == 8, try uint(4) > 256 { throw ylRtmpLimit() }
        var object: [String: Any] = [:]
        while true {
          let key = try string(Int(uint(2)))
          if key.isEmpty, at < bytes.count, bytes[at] == 9 { at += 1; return object }
          guard object[key] == nil else { throw ylRtmpInvalid() }
          object[key] = try value(depth + 1)
        }
      case 5,6: return NSNull()
      case 10:
        let count = try uint(4); guard count <= 256 else { throw ylRtmpLimit() }
        return try (0..<Int(count)).map { _ in try value(depth + 1) }
      case 12: return try string(Int(uint(4)))
      default: throw ylRtmpInvalid()
      }
    }
    var result: [Any] = []
    while at < bytes.count { result.append(try value(0)) }; return result
  }
  static func encode(_ values: [Any]) throws -> Data {
    var out = Data(), entries = 0
    func string(_ value: String) throws {
      let bytes = Data(value.utf8); guard bytes.count <= 16384 else { throw ylRtmpLimit() }
      out.rtmpBE(UInt64(bytes.count), 2); out.append(bytes)
    }
    func value(_ item: Any, _ depth: Int) throws {
      entries += 1; guard entries <= 256 && depth <= 8 else { throw ylRtmpLimit() }
      if let s = item as? String { out.append(2); try string(s) }
      else if let b = item as? Bool { out.append(contentsOf: [1,b ? 1 : 0]) }
      else if let n = item as? Double { guard n.isFinite else { throw ylRtmpInvalid() }; out.append(0); out.rtmpBE(n.bitPattern,8) }
      else if let object = item as? [String: Any] {
        out.append(3)
        for key in object.keys.sorted() { try string(key); try value(object[key]!,depth+1) }
        out.append(contentsOf: [0,0,9])
      } else if item is NSNull { out.append(5) }
      else { throw ylRtmpInvalid() }
      guard out.count <= 65536 else { throw ylRtmpLimit() }
    }
    for item in values { try value(item,0) }; return out
  }
}

/// Bounded pending wire bytes, with modular acknowledgements and peer bandwidth credit.
final class YlRtmpFlowControl {
  private let send: (Data) throws -> Void
  private var pending = Data()
  private var sent: UInt64 = 3073, acknowledged: UInt64 = 0
  private var window: UInt64?
  private var previousLimit = 2
  var pendingBytes: Int { pending.count }
  init(send: @escaping (Data) throws -> Void) { self.send = send }
  func bandwidth(_ size: UInt32, mode: Int) throws -> UInt32? {
    guard size > 0 && (0...2).contains(mode) else { throw ylRtmpInvalid() }
    if mode == 2 && previousLimit != 0 { return nil }
    let effective = mode == 1 ? min(window ?? UInt64(size),UInt64(size)) : UInt64(size)
    previousLimit = mode == 2 ? 0 : mode
    let changed = window != effective; window = effective
    return changed ? UInt32(effective) : nil
  }
  func acknowledge(_ sequence: UInt32) throws {
    let delta = sequence &- UInt32(truncatingIfNeeded: acknowledged)
    guard UInt64(delta) <= sent - acknowledged else { throw ylRtmpInvalid() }
    acknowledged += UInt64(delta); try flush()
  }
  func write(_ message: YlRtmpMessage) throws {
    guard message.payload.count <= 65536 else { throw ylRtmpLimit() }
    var bytes = Data([message.type <= 6 ? 2 : 3])
    let ext = message.timestamp >= 0xffffff
    bytes.rtmpBE(UInt64(ext ? 0xffffff : message.timestamp),3)
    bytes.rtmpBE(UInt64(message.payload.count),3); bytes.append(UInt8(message.type))
    for shift in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: message.stream >> (shift*8))) }
    if ext { bytes.rtmpBE(UInt64(message.timestamp),4) }
    var offset = 0
    while offset < message.payload.count {
      if offset > 0 { bytes.append(message.type <= 6 ? 0xc2 : 0xc3); if ext { bytes.rtmpBE(UInt64(message.timestamp),4) } }
      let n = min(128,message.payload.count-offset)
      bytes.append(message.payload.subdata(in: offset..<offset+n)); offset += n
    }
    try flush()
    guard bytes.count <= 65536 - pending.count else { throw ylRtmpLimit() }
    pending.append(bytes); try flush()
  }
  func flush() throws {
    let credit = window.map { $0 > sent-acknowledged ? $0-(sent-acknowledged) : 0 } ?? UInt64.max
    let count = Int(min(UInt64(pending.count),credit))
    if count > 0 {
      try send(pending.subdata(in: 0..<count)); pending = Data(pending.dropFirst(count)); sent += UInt64(count)
    }
  }
}

final class YlRtmpFlvStream {
  private var declared = false
  private var video: Data?, audio: Data?
  private var nalLength = 4
  private var times: [Int: UInt32] = [:]
  func header() throws -> Data {
    guard video != nil else { throw ylRtmpInvalid() }; declared = true
    return Data([70,76,86,1,audio == nil ? 1 : 5,0,0,0,9,0,0,0,0])
  }
  func accept(_ m: YlRtmpMessage) throws -> Data? {
    guard [8,9].contains(m.type) else { return nil }
    let p = m.payload
    guard !p.isEmpty else { throw ylRtmpInvalid() }
    var nextLength = nalLength
    if m.type == 9 {
      guard p[0]&0x80 == 0 && p[0]&15 == 7 else { throw ylRtmpError("container.unsupported") }
      guard p.count >= 5 && (1...5).contains(p[0] >> 4) else { throw ylRtmpInvalid() }
      switch p[1] {
      case 0: nextLength = try validateAVC(p)
      case 1:
        guard video != nil, p.count > 5 + nalLength else { throw ylRtmpInvalid() }
        var at = 5
        while at < p.count {
          guard nalLength <= p.count-at else { throw ylRtmpInvalid() }
          let n = Int(p.rtmpUInt(at,nalLength)); at += nalLength
          guard n > 0 && n <= p.count-at else { throw ylRtmpInvalid() }; at += n
        }
      case 2:
        guard p.count == 5 else { throw ylRtmpInvalid() }; return nil
      default: throw ylRtmpInvalid()
      }
    } else {
      guard p[0] >> 4 == 10 else { throw ylRtmpError("container.unsupported") }
      guard p.count >= 3 else { throw ylRtmpInvalid() }
      switch p[1] {
      case 0:
        guard p.count >= 4 else { throw ylRtmpInvalid() }
        guard [1,2,3,4,5,29].contains(p[2]>>3) else { throw ylRtmpError("container.unsupported") }
      case 1: guard audio != nil else { throw ylRtmpInvalid() }
      default: throw ylRtmpInvalid()
      }
    }
    if let previous = times[m.type], UInt64(m.timestamp)+2000 < UInt64(previous) || (previous > 0xffff0000 && m.timestamp < 65536) {
      throw ylRtmpError("network.rtmp_disconnected")
    }
    if p[1] == 0 {
      let old = m.type == 9 ? video : audio
      if declared && old != p { throw ylRtmpError("container.rtmp_track_layout_changed") }
      if m.type == 9 { video = p; nalLength = nextLength } else { audio = p }
    }
    times[m.type] = max(times[m.type] ?? 0,m.timestamp)
    var tag = Data([UInt8(m.type)])
    tag.rtmpBE(UInt64(p.count),3); tag.rtmpBE(UInt64(m.timestamp&0xffffff),3)
    tag.append(UInt8(m.timestamp>>24)); tag.append(contentsOf: [0,0,0]); tag.append(p)
    tag.rtmpBE(UInt64(p.count+11),4); return tag
  }
  private func validateAVC(_ p: Data) throws -> Int {
    guard p.count >= 12 && p[5] == 1 else { throw ylRtmpInvalid() }
    let length = Int(p[9]&3)+1; guard length != 3 else { throw ylRtmpInvalid() }
    var at = 11
    func nal() throws {
      guard p.count-at >= 2 else { throw ylRtmpInvalid() }
      let count = Int(p.rtmpUInt(at,2)); at += 2
      guard count > 0 && count <= p.count-at else { throw ylRtmpInvalid() }; at += count
    }
    let sps = p[10]&31; guard sps > 0 else { throw ylRtmpInvalid() }
    for _ in 0..<sps { try nal() }
    guard at < p.count else { throw ylRtmpInvalid() }; let pps = p[at]; at += 1
    guard pps > 0 else { throw ylRtmpInvalid() }
    for _ in 0..<pps { try nal() }
    return length
  }
}
