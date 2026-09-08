import Foundation

enum YlPacketKind: Equatable {
  case video
  case audio
}

struct YlPacketEnvelope {
  let packet: AnyObject
  let kind: YlPacketKind
  let ptsUs: Int64
  let dtsUs: Int64
  let durationUs: Int64
  let byteCount: Int
  let keyframe: Bool
  let generation: UInt64
}

enum YlQueuePushResult: Equatable {
  case accepted
  case wouldExceedDuration
  case wouldExceedBytes
  case cancelled
}

final class YlBoundedPacketQueue {
  private let condition = NSCondition()
  private let maxDurationUs: Int64
  private let maxBytes: Int
  private var packets = [YlPacketEnvelope]()
  private var durationUs: Int64 = 0
  private var bytes = 0
  private var cancelled = false

  init(maxDurationUs: Int64, maxBytes: Int) {
    precondition(maxDurationUs >= 0)
    precondition(maxBytes >= 0)
    self.maxDurationUs = maxDurationUs
    self.maxBytes = maxBytes
  }

  var count: Int {
    condition.withLock { packets.count }
  }

  var bufferedDurationUs: Int64 {
    condition.withLock { durationUs }
  }

  var bufferedBytes: Int {
    condition.withLock { bytes }
  }

  var isCancelled: Bool {
    condition.withLock { cancelled }
  }

  func push(_ packet: YlPacketEnvelope) -> YlQueuePushResult {
    condition.lock()
    defer { condition.unlock() }
    guard !cancelled else { return .cancelled }
    let result = capacityResult(for: packet)
    guard result == .accepted else { return result }
    append(packet)
    condition.broadcast()
    return .accepted
  }

  func waitAndPush(_ packet: YlPacketEnvelope) -> YlQueuePushResult {
    condition.lock()
    defer { condition.unlock() }

    let packetDuration = max(0, packet.durationUs)
    if packet.byteCount > maxBytes { return .wouldExceedBytes }
    if packetDuration > maxDurationUs { return .wouldExceedDuration }

    while true {
      guard !cancelled else { return .cancelled }
      if capacityResult(for: packet) == .accepted {
        append(packet)
        condition.broadcast()
        return .accepted
      }
      condition.wait()
    }
  }

  func pop() -> YlPacketEnvelope? {
    condition.lock()
    guard !packets.isEmpty else {
      condition.unlock()
      return nil
    }
    let packet = packets.removeFirst()
    durationUs -= max(0, packet.durationUs)
    bytes -= max(0, packet.byteCount)
    condition.broadcast()
    condition.unlock()
    return packet
  }

  func cancel() {
    condition.lock()
    cancelled = true
    let releasedPackets = packets
    packets.removeAll(keepingCapacity: false)
    durationUs = 0
    bytes = 0
    condition.broadcast()
    condition.unlock()
    withExtendedLifetime(releasedPackets) {}
  }

  func reset() {
    condition.lock()
    let releasedPackets = packets
    packets.removeAll(keepingCapacity: true)
    durationUs = 0
    bytes = 0
    cancelled = false
    condition.broadcast()
    condition.unlock()
    withExtendedLifetime(releasedPackets) {}
  }

  private func capacityResult(for packet: YlPacketEnvelope) -> YlQueuePushResult {
    let packetBytes = max(0, packet.byteCount)
    let (nextBytes, bytesOverflow) = bytes.addingReportingOverflow(packetBytes)
    if bytesOverflow || nextBytes > maxBytes {
      return .wouldExceedBytes
    }

    let packetDuration = max(0, packet.durationUs)
    let (nextDuration, durationOverflow) = durationUs.addingReportingOverflow(packetDuration)
    if durationOverflow || nextDuration > maxDurationUs {
      return .wouldExceedDuration
    }
    return .accepted
  }

  private func append(_ packet: YlPacketEnvelope) {
    packets.append(packet)
    durationUs += max(0, packet.durationUs)
    bytes += max(0, packet.byteCount)
  }

  deinit {
    cancel()
  }
}

private extension NSCondition {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
