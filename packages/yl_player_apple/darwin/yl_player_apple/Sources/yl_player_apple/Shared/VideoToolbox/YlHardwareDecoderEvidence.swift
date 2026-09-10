import Foundation
import VideoToolbox

/// Positive evidence has a CFBoolean type, never an NSNumber/Swift bridge guess.
/// The identity is deliberately framework-owned and cannot contain source data.
struct YlHardwareDecoderEvidence: Equatable {
  enum Mode: String { case unknown, hardware, software }
  let mode: Mode
  var decoderName: String { "VideoToolbox" }
  static let unknown = Self(mode: .unknown)
  init(mode: Mode) { self.mode = mode }
  init(status: OSStatus, value: CFTypeRef?) {
    guard status == noErr, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
      self.mode = .unknown; return
    }
    self.mode = CFEqual(value, kCFBooleanTrue) ? .hardware : .software
  }
}

struct YlVTSessionPropertyReader {
  typealias Copy = (VTSession, CFString, inout CFTypeRef?) -> OSStatus
  var copy: Copy = { session, key, value in
    VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: &value)
  }
  func evidence(for session: VTSession) -> YlHardwareDecoderEvidence {
    var value: CFTypeRef?
    // Named SDK constant is iOS 17+. This verified key also supports iOS 15/16.
    let status = copy(session, "UsingHardwareAcceleratedVideoDecoder" as CFString, &value)
    return YlHardwareDecoderEvidence(status: status, value: value)
  }
}

extension YlHardwareDecoderEvidence {
  static func unavailable() -> NativePlayerError {
    NativePlayerError(category: "decoder", code: "decoder.unavailable",
      message: "Positive hardware decoder evidence is unavailable.")
  }
}

/// One pending native probe per Player. Timeouts retire its result authority,
/// while the serial worker retains all actual owners until native work returns.
final class YlHardwareEvidencePreparation {
  typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
  private final class Operation<Value> {
    let condition = NSCondition()
    var completed = false
    var result: Result<Value, Error>?
    func finish(_ result: Result<Value, Error>) -> Bool {
      condition.lock(); defer { condition.unlock() }
      guard !completed else { return false }
      completed = true; self.result = result; condition.broadcast(); return true
    }
    func take() throws -> Value {
      condition.lock(); defer { condition.unlock() }
      while !completed { condition.wait() }
      let value = result!; result = nil; return try value.get()
    }
  }
  private let lock = NSLock()
  private var busy = false
  private let queue = DispatchQueue(label: "dev.ylplayer.hardware-evidence", qos: .userInitiated)
  private let now: () -> TimeInterval
  private let schedule: Schedule
  private let timeout: TimeInterval
  init(timeout: TimeInterval = 5,
       now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       schedule: Schedule? = nil) {
    self.timeout = timeout; self.now = now
    self.schedule = schedule ?? { seconds, action in
      let item = DispatchWorkItem(block: action)
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
      return { item.cancel() }
    }
  }
  func run<Value>(token: YlOpenCancellationToken, work: @escaping () throws -> Value,
                  discard: @escaping (Value) -> Void) throws -> Value {
    precondition(!Thread.isMainThread)
    try token.throwIfCancelled()
    let admitted = lock.withLock { () -> Bool in
      guard !busy else { return false }; busy = true; return true
    }
    guard admitted else { throw YlHardwareDecoderEvidence.unavailable() }
    let operation = Operation<Value>()
    let deadline = now() + timeout
    let cancelTimer = schedule(timeout) {
      _ = operation.finish(.failure(YlHardwareDecoderEvidence.unavailable()))
    }
    token.onCancel { [weak operation] in
      _ = operation?.finish(.failure(YlOpenCancellationToken.cancellationError()))
    }
    queue.async { [self] in
      defer { lock.withLock { busy = false } }
      do {
        try token.throwIfCancelled()
        guard now() < deadline else { throw YlHardwareDecoderEvidence.unavailable() }
        let value = try work()
        if token.isCancelled || now() >= deadline {
          discard(value)
          _ = operation.finish(.failure(token.isCancelled ? YlOpenCancellationToken.cancellationError() : YlHardwareDecoderEvidence.unavailable()))
        } else if !operation.finish(.success(value)) { discard(value) }
      } catch { _ = operation.finish(.failure(error)) }
    }
    defer { cancelTimer() }
    return try operation.take()
  }
}
