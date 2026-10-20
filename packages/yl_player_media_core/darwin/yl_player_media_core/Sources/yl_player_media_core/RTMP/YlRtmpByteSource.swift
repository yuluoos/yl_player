import Foundation
import Network
import Security

/// One attempt, one socket, one parser/FLV epoch. The worker never retries.
/// Temporary AVIO interruption only stops consumer demand. The worker retains
/// its parser stack and any incomplete socket receive until demand resumes.
public final class YlRtmpByteSource: YlByteSource {
  private let configureTLS: ((NWProtocolTLS.Options) -> Void)?
  private let recipe: YlRtmpRequestRecipe
  private let setupNanos: UInt64, inactivityNanos: UInt64
  private let condition = NSCondition()
  private let networkQueue = DispatchQueue(label: "yl.rtmp.network")
  private var connection: NWConnection?
  private var timer: DispatchSourceTimer?
  private var started = false, cancelled = false, interrupted = false
  private var prepared = false, established = false, ready = false
  private var demand = false, readPending = false, playbackPaused = false
  private var activeSince: UInt64?
  private var remaining: UInt64, openingDeadline: UInt64 = .max
  private var failure: NativePlayerError?
  private var ioFinished = false, ioBytes: Data?
  private var outputs: [Data] = [], outputOffset = 0
  private var offset: Int64 = 0
  private var reservation: YlManagedBufferLedger.Token?
  // The fields below are exclusively owned by the parser worker.
  private var reader: YlRtmpChunkReader!
  private var flow: YlRtmpFlowControl!
  private var flv: YlRtmpFlvStream! = YlRtmpFlvStream()
  private var stage = 0, stream: UInt32 = 0
  private var received: UInt64 = 0, acknowledged: UInt64 = 0, ackWindow: UInt64 = 0
  private var videoConfig: Data?, audioConfig: Data?

  public init(recipe: YlRtmpRequestRecipe, setupMs: Int = 10000, inactivityMs: Int = 15000,
       configureTLS: ((NWProtocolTLS.Options) -> Void)? = nil) {
    self.recipe = recipe
    self.configureTLS = configureTLS
    recipe.bufferScope.recordNetworkBytes(0)
    setupNanos = UInt64(max(1,setupMs)) * 1_000_000
    inactivityNanos = UInt64(max(1,inactivityMs)) * 1_000_000
    remaining = inactivityNanos
  }
  public var hasOutstandingRead: Bool { condition.lock(); defer { condition.unlock() }; return readPending && outputs.isEmpty }
  public var length: Int64? { nil }
  public var supportsRandomAccess: Bool { false }
  public var currentOffset: Int64 { condition.lock(); defer { condition.unlock() }; return offset }
  private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  private func transportErrorLocked(_ error: NWError? = nil) -> NativePlayerError {
    if let error, case .tls = error { return ylRtmpError("network.rtmp_tls_failed") }
    return ylRtmpError(prepared ? "network.rtmp_disconnected" : "network.rtmp_handshake_failed")
  }
  private func expiredLocked() -> Bool {
    let time = now()
    if !prepared { return time >= openingDeadline }
    return activeSince.map { time &- $0 >= remaining } ?? false
  }
  private func checkLocked() throws {
    if cancelled { throw YlByteSourceError.cancelled }
    if failure == nil && expiredLocked() { failure = transportErrorLocked(); connection?.cancel() }
    if let failure { throw failure }
  }
  private func check() throws { condition.lock(); defer { condition.unlock() }; try checkLocked() }
  private func suspendDemandLocked() {
    if let start = activeSince { let elapsed = now() &- start; remaining = remaining > elapsed ? remaining - elapsed : 0 }
    activeSince = nil; demand = false
  }
  private func acceptedMedia() {
    condition.lock(); remaining = inactivityNanos
    if activeSince != nil { activeSince = now() }; condition.unlock()
  }
  public func finishPreparation() throws {
    condition.lock(); defer { condition.unlock() }
    try checkLocked()
    guard established else { throw ylRtmpInvalid() }
    prepared = true; remaining = inactivityNanos
    if playbackPaused { suspendDemandLocked() }
    activeSince = demand ? now() : nil
  }
  public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    condition.lock(); readPending = true
    defer { readPending = false; suspendDemandLocked(); condition.broadcast(); condition.unlock() }
    do {
      if cancelled || interrupted { throw YlByteSourceError.cancelled }
      try checkLocked()
      if buffer.isEmpty { return 0 }
      if !started {
        // Covers all retained partial payloads, startup tags, COW tag construction,
        // 64KiB NW receives, bounded AMF values and the pending control workspace.
        guard let token = recipe.bufferScope.reserve(category: .networkCache, bytes: 32 * 1024 * 1024) else { throw ylRtmpLimit() }
        reservation = token; started = true; openingDeadline = now() + setupNanos
        DispatchQueue.global(qos: .userInitiated).async { [self] in produce() }
      }
      demand = !prepared || !playbackPaused
      if prepared && demand && activeSince == nil { activeSince = now() }
      condition.broadcast()
      while outputs.isEmpty || (prepared && playbackPaused) {
        if cancelled || interrupted { throw YlByteSourceError.cancelled }
        try checkLocked(); condition.wait()
      }
      if cancelled || interrupted { throw YlByteSourceError.cancelled }
      try checkLocked()
      let count = min(buffer.count,outputs[0].count-outputOffset)
      outputs[0].copyBytes(to: buffer.bindMemory(to: UInt8.self), from: outputOffset..<outputOffset+count)
      outputOffset += count; offset += Int64(count)
      if outputOffset == outputs[0].count { outputs.removeFirst(); outputOffset = 0 }
      return count
    } catch let error as NativePlayerError { throw YlByteSourceError.failed(error) }
  }
  public func seek(to offset: Int64) throws -> Int64 {
    throw YlByteSourceError.failed(ylRtmpError("source.not_seekable"))
  }
  public func interruptRead() {
    condition.lock(); interrupted = true; suspendDemandLocked(); condition.broadcast(); condition.unlock()
  }
  public func resumeReads() { condition.lock(); interrupted = false; condition.broadcast(); condition.unlock() }
  /// Playback pause retains the blocked AVIO/parser stack. It does not signal
  /// callback cancellation, consume idle time, or relax the opening deadline.
  public func setPlaybackPaused(_ paused: Bool) {
    condition.lock(); defer { condition.broadcast(); condition.unlock() }
    playbackPaused = paused
    guard prepared else { return }
    if paused { suspendDemandLocked() }
    else if readPending && !interrupted && !cancelled {
      demand = true; if activeSince == nil { activeSince = now() }
    }
  }
  public func cancel() {
    condition.lock(); cancelled = true; suspendDemandLocked(); outputs.removeAll(); outputOffset = 0
    let socket = connection, alarm = timer; timer = nil
    condition.broadcast(); condition.unlock(); alarm?.cancel(); socket?.cancel()
  }
  public func handleMemoryWarning() {}

  private func waitForDemand() throws {
    condition.lock(); defer { condition.unlock() }
    while !demand || interrupted || !outputs.isEmpty { try checkLocked(); condition.wait() }
    try checkLocked()
  }
  private func deliver(_ data: [Data]) throws {
    condition.lock(); defer { condition.unlock() }; try checkLocked()
    // A single media message or the four startup pieces; never an unbounded producer queue.
    guard outputs.isEmpty else { throw ylRtmpLimit() }
    outputs = data; condition.broadcast()
  }
  private func produce() {
    defer {
      condition.lock(); let socket = connection, alarm = timer; timer = nil
      condition.unlock(); socket?.cancel(); alarm?.cancel()
      reader = nil; flow = nil; flv = nil; videoConfig = nil; audioConfig = nil
      condition.lock(); ioBytes = nil; reservation = nil; condition.broadcast(); condition.unlock()
    }
    do {
      try connect()
      try handshake()
      flow = YlRtmpFlowControl { [unowned self] bytes in try send(bytes) }
      reader = YlRtmpChunkReader { [unowned self] count in try exact(count) }
      try command(0, ["connect",1.0, ["app":recipe.address.app,"tcUrl":recipe.address.tcURL,
        "flashVer":"FMLE/3.0","fpad":false,"capabilities":15.0,"audioCodecs":1024.0,
        "videoCodecs":128.0,"videoFunction":1.0,"objectEncoding":0.0] as [String: Any]])
      while true {
        try waitForDemand()
        let message = try reader.next()
        try process(message)
      }
    } catch {
      condition.lock()
      if !cancelled && failure == nil { failure = (error as? NativePlayerError) ?? transportErrorLocked() }
      outputs.removeAll(); outputOffset = 0; condition.broadcast(); condition.unlock()
    }
  }
  private func connect() throws {
    condition.lock(); defer { condition.unlock() }; try checkLocked()
    let parameters: NWParameters
    if recipe.address.secure {
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, recipe.address.host)
      sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
      sec_protocol_options_append_tls_ciphersuite_group(tls.securityProtocolOptions, .ats)
      sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
      configureTLS?(tls) // Internal fixture seam; production retains system trust and hostname checks.
      parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    } else { parameters = .tcp }
    let socket = NWConnection(host: NWEndpoint.Host(recipe.address.host), port: NWEndpoint.Port(rawValue: recipe.address.port)!, using: parameters)
    connection = socket
    socket.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      self.condition.lock(); defer { self.condition.unlock() }
      switch state {
      case .ready: self.ready = true
      case let .failed(error):
        if self.failure == nil && !self.cancelled { self.failure = self.transportErrorLocked(error) }
      case let .waiting(error):
        // Certificate failures must terminate rather than becoming a retryable setup timeout.
        if case .tls = error, self.failure == nil && !self.cancelled {
          self.failure = self.transportErrorLocked(error); self.connection?.cancel()
        }
      case .cancelled: if !self.cancelled && self.failure == nil { self.failure = self.transportErrorLocked() }
      default: break
      }
      self.condition.broadcast()
    }
    let alarm = DispatchSource.makeTimerSource(queue: networkQueue)
    alarm.schedule(deadline: .now(), repeating: .milliseconds(10))
    alarm.setEventHandler { [weak self] in
      guard let self else { return }; self.condition.lock()
      if !self.cancelled && self.failure == nil && self.expiredLocked() {
        self.failure = self.transportErrorLocked(); self.connection?.cancel(); self.condition.broadcast()
      }
      self.condition.unlock()
    }
    timer = alarm; alarm.resume(); socket.start(queue: networkQueue)
    while !ready { try checkLocked(); condition.wait() }; try checkLocked()
  }
  private func send(_ bytes: Data) throws {
    condition.lock(); defer { condition.unlock() }; try checkLocked()
    ioFinished = false
    connection!.send(content: bytes, completion: .contentProcessed { [weak self] error in
      guard let self else { return }; self.condition.lock()
      if let error, self.failure == nil && !self.cancelled { self.failure = self.transportErrorLocked(error) }
      self.ioFinished = true; self.condition.broadcast(); self.condition.unlock()
    })
    while !ioFinished { try checkLocked(); condition.wait() }; try checkLocked()
  }
  private func receive(_ count: Int) throws -> Data {
    condition.lock(); defer { condition.unlock() }; try checkLocked()
    ioFinished = false; ioBytes = nil
    connection!.receive(minimumIncompleteLength: 1, maximumLength: count) { [weak self] data, _, eof, error in
      guard let self else { return }; self.condition.lock()
      if self.cancelled || self.failure != nil { self.ioFinished = true; self.condition.broadcast(); self.condition.unlock(); return }
      if let data { self.recipe.bufferScope.recordNetworkBytes(data.count) }
      self.ioBytes = data
      if (error != nil || (eof && (data?.isEmpty ?? true))) && self.failure == nil && !self.cancelled {
        self.failure = self.transportErrorLocked(error)
      }
      self.ioFinished = true; self.condition.broadcast(); self.condition.unlock()
    }
    while !ioFinished { try checkLocked(); condition.wait() }; try checkLocked()
    guard let bytes = ioBytes, !bytes.isEmpty else { throw transportErrorLocked() }
    ioBytes = nil; return bytes
  }
  private func exact(_ count: Int) throws -> Data {
    guard count <= 65536 else { throw ylRtmpLimit() }
    var result = Data(); result.reserveCapacity(count)
    while result.count < count {
      try check(); try flow?.flush()
      var amount = count-result.count
      if ackWindow > 0 { amount = min(amount, Int(max(1,ackWindow-min(ackWindow,received-acknowledged)))) }
      let bytes = try receive(amount); result.append(bytes); received += UInt64(bytes.count)
      if ackWindow > 0 && received-acknowledged >= ackWindow {
        acknowledged = received; try control(3, UInt32(truncatingIfNeeded: received))
      }
    }
    return result
  }
  private func handshake() throws {
    var c1 = Data((0..<1536).map { _ in UInt8.random(in: 0...255) })
    c1.replaceSubrange(0..<8,with: repeatElement(UInt8(0),count:8))
    try send(Data([3])+c1)
    guard try exact(1) == Data([3]) else { throw ylRtmpInvalid() }
    let s1 = try exact(1536); try send(s1)
    let s2 = try exact(1536)
    guard s2.dropFirst(8) == c1.dropFirst(8) else { throw ylRtmpInvalid() }
  }
  private func command(_ id: UInt32, _ values: [Any]) throws {
    try flow.write(.init(type: 20,stream:id,timestamp:0,payload:YlRtmpAmf.encode(values)))
  }
  private func control(_ type: Int, _ value: UInt32) throws {
    var bytes = Data(); bytes.rtmpBE(UInt64(value),4)
    try flow.write(.init(type:type,stream:0,timestamp:0,payload:bytes))
  }
  private func process(_ m: YlRtmpMessage) throws {
    try check()
    let p = m.payload
    func size(_ count: Int) throws { if p.count != count { throw ylRtmpInvalid() } }
    if m.type <= 6 {
      guard m.stream == 0 else { throw ylRtmpInvalid() }
      switch m.type {
      case 1: try size(4); try reader.setChunkSize(UInt32(p.rtmpUInt(0,4)))
      case 2:
        try size(4); let id = p.rtmpUInt(0,4); guard (2...65599).contains(id) else { throw ylRtmpInvalid() }; reader.abort(Int(id))
      case 3: try size(4); try flow.acknowledge(UInt32(p.rtmpUInt(0,4)))
      case 4:
        guard p.count >= 2 else { throw ylRtmpInvalid() }
        let event = p.rtmpUInt(0,2)
        switch event {
        case 6:
          try size(6); var reply = p; reply[1] = 7
          try flow.write(.init(type:4,stream:0,timestamp:0,payload:reply))
        case 0,1,2,4:
          try size(6); if stream != 0 && p.rtmpUInt(2,4) != UInt64(stream) { throw ylRtmpInvalid() }
          if event == 1 { throw ylRtmpError(established ? "network.rtmp_disconnected" : "network.rtmp_stream_unavailable") }
        case 3: try size(10)
        case 7: try size(6)
        default: throw ylRtmpInvalid()
        }
      case 5:
        try size(4); ackWindow = p.rtmpUInt(0,4); guard ackWindow > 0 else { throw ylRtmpInvalid() }
        if received-acknowledged >= ackWindow { acknowledged = received; try control(3,UInt32(truncatingIfNeeded: received)) }
      case 6:
        try size(5)
        if let effective = try flow.bandwidth(UInt32(p.rtmpUInt(0,4)),mode:Int(p[4])) { try control(5,effective) }
      default: throw ylRtmpInvalid()
      }
      return
    }
    if m.type == 20 { try onCommand(m); return }
    guard m.stream == stream && stage >= 2 else { throw ylRtmpInvalid() }
    if m.type == 18 { _ = try YlRtmpAmf.decode(p); return }
    guard stage == 3 else { throw ylRtmpInvalid() }
    guard let tag = try flv.accept(m) else { return }
    if !established {
      if m.type == 9 && p[1] == 0 { videoConfig = tag }
      if m.type == 8 && p[1] == 0 { audioConfig = tag }
      if m.type == 9 && p[1] == 1 && p[0] >> 4 == 1, let videoConfig {
        var initial = [try flv.header(),videoConfig]
        if let audioConfig { initial.append(audioConfig) }; initial.append(tag)
        condition.lock(); established = true; condition.unlock()
        self.videoConfig = nil; self.audioConfig = nil
        try deliver(initial)
      }
    } else {
      if p[1] == 1 { acceptedMedia() }
      try deliver([tag])
    }
  }
  private func onCommand(_ m: YlRtmpMessage) throws {
    let values = try YlRtmpAmf.decode(m.payload)
    guard values.count >= 2, let name = values[0] as? String, let tx = values[1] as? Double else { throw ylRtmpInvalid() }
    if name == "_error" { throw ylRtmpError("network.rtmp_stream_unavailable") }
    switch name {
    case "_result":
      guard values.count >= 4 && m.stream == 0 else { throw ylRtmpInvalid() }
      if stage == 0 && tx == 1 {
        guard let info = values[3] as? [String: Any] else { throw ylRtmpInvalid() }
        guard info["code"] as? String == "NetConnection.Connect.Success" else { throw ylRtmpError("network.rtmp_stream_unavailable") }
        stage = 1; try command(0,["createStream",2.0,NSNull()])
      } else if stage == 1 && tx == 2 {
        guard let id = values[3] as? Double, id >= 1, id <= Double(Int32.max), id.rounded() == id else { throw ylRtmpInvalid() }
        stream = UInt32(id); stage = 2
        var buffer = Data([0,3]); buffer.rtmpBE(UInt64(stream),4); buffer.rtmpBE(1000,4)
        try flow.write(.init(type:4,stream:0,timestamp:0,payload:buffer))
        try command(stream,["play",0.0,NSNull(),recipe.address.playpath,-1.0])
      } else { throw ylRtmpInvalid() }
    case "onStatus":
      guard values.count >= 4, tx == 0, m.stream == stream, stage >= 2,
        let info = values[3] as? [String: Any], let code = info["code"] as? String else { throw ylRtmpInvalid() }
      guard info["level"] as? String != "error" else { throw ylRtmpError("network.rtmp_stream_unavailable") }
      switch code {
      case "NetStream.Play.Start": stage = 3
      case "NetStream.Play.Reset", "NetStream.Data.Start", "NetStream.Play.PublishNotify": break
      default: throw ylRtmpError("network.rtmp_stream_unavailable")
      }
    case "onBWDone": if m.stream != 0 { throw ylRtmpInvalid() }
    default: throw ylRtmpInvalid()
    }
  }
}
