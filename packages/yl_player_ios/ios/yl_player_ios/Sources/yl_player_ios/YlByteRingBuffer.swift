import Foundation

final class YlByteRingBuffer {
  private let condition = NSCondition()
  private var storage: [UInt8]
  private var capacityLimit: Int
  private var head = 0
  private var storedCount = 0
  private var startOffset: Int64 = 0
  private var readOffset: Int64 = 0
  private var hasEstablishedOffset = false
  private var finished = false
  private var cancelled = false
  private var failure: NativePlayerError?

  init(capacity: Int) {
    precondition(capacity > 0)
    storage = [UInt8](repeating: 0, count: capacity)
    capacityLimit = capacity
  }

  var capacity: Int {
    condition.withLock { capacityLimit }
  }

  var bufferedBytes: Int {
    condition.withLock { storedCount }
  }

  var currentOffset: Int64 {
    condition.withLock { readOffset }
  }

  var retainedStartOffset: Int64 {
    condition.withLock { startOffset }
  }

  var retainedEndOffset: Int64 {
    condition.withLock { endOffset }
  }

  func append(_ data: Data, at offset: Int64) throws -> Int {
    try data.withUnsafeBytes { bytes in
      try condition.withLock {
        try appendLocked(bytes, at: offset)
      }
    }
  }

  func write(_ data: Data, at offset: Int64) throws {
    try data.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let appended = try condition.withLock {
          try appendLocked(
            UnsafeRawBufferPointer(rebasing: bytes[written...]),
            at: offset + Int64(written)
          )
        }
        if appended > 0 {
          written += appended
          continue
        }
        try waitForWritableCapacity()
      }
    }
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    guard !buffer.isEmpty else { return 0 }
    condition.lock()
    defer { condition.unlock() }
    while true {
      if cancelled { throw YlByteSourceError.cancelled }
      let unread = unreadCount
      if unread > 0 {
        let count = min(buffer.count, unread)
        copyOutLocked(into: buffer, count: count)
        readOffset += Int64(count)
        if storedCount > capacityLimit || storage.count != capacityLimit {
          discardConsumedLocked(maximum: storedCount)
          resizeStorageIfPossibleLocked()
        }
        condition.broadcast()
        return count
      }
      if let failure { throw YlByteSourceError.failed(failure) }
      if finished { return 0 }
      condition.wait()
    }
  }

  func seekWithinBuffer(to offset: Int64) -> Bool {
    condition.withLock {
      guard !cancelled, offset >= startOffset, offset <= endOffset else {
        return false
      }
      readOffset = offset
      condition.broadcast()
      return true
    }
  }

  func reset(at offset: Int64) {
    condition.withLock {
      head = 0
      storedCount = 0
      startOffset = offset
      readOffset = offset
      hasEstablishedOffset = true
      finished = false
      failure = nil
      resizeStorageIfPossibleLocked()
      condition.broadcast()
    }
  }

  func finish() {
    condition.withLock {
      guard !finished, !cancelled, failure == nil else { return }
      finished = true
      condition.broadcast()
    }
  }

  func fail(_ error: NativePlayerError) {
    condition.withLock {
      guard !cancelled, failure == nil, !finished else { return }
      failure = error
      condition.broadcast()
    }
  }

  func cancel() {
    condition.withLock {
      guard !cancelled else { return }
      cancelled = true
      condition.broadcast()
    }
  }

  func shrink(to newCapacity: Int) {
    precondition(newCapacity > 0)
    condition.withLock {
      capacityLimit = min(capacityLimit, newCapacity)
      discardConsumedLocked(maximum: storedCount)
      resizeStorageIfPossibleLocked()
      condition.broadcast()
    }
  }

  private var endOffset: Int64 {
    startOffset + Int64(storedCount)
  }

  private var unreadCount: Int {
    Int(endOffset - readOffset)
  }

  private var consumedCount: Int {
    Int(readOffset - startOffset)
  }

  private func appendLocked(
    _ bytes: UnsafeRawBufferPointer,
    at offset: Int64
  ) throws -> Int {
    try throwIfNotWritableLocked()
    if !hasEstablishedOffset && storedCount == 0 {
      startOffset = offset
      readOffset = offset
      hasEstablishedOffset = true
    }
    guard offset == endOffset else {
      throw YlByteSourceError.invalidOffset(expected: endOffset, actual: offset)
    }
    guard !bytes.isEmpty else { return 0 }

    let immediatelyAvailable = max(0, capacityLimit - storedCount)
    let desired = min(bytes.count, capacityLimit)
    if immediatelyAvailable < desired {
      discardConsumedLocked(maximum: desired - immediatelyAvailable)
    }
    resizeStorageIfPossibleLocked()
    let writable = min(bytes.count, max(0, capacityLimit - storedCount))
    guard writable > 0 else { return 0 }
    copyInLocked(from: bytes, count: writable)
    storedCount += writable
    condition.broadcast()
    return writable
  }

  private func waitForWritableCapacity() throws {
    condition.lock()
    defer { condition.unlock() }
    while true {
      try throwIfNotWritableLocked()
      if capacityLimit - storedCount + consumedCount > 0 { return }
      condition.wait()
    }
  }

  private func throwIfNotWritableLocked() throws {
    if cancelled { throw YlByteSourceError.cancelled }
    if let failure { throw YlByteSourceError.failed(failure) }
    if finished { throw YlByteSourceError.closed }
  }

  private func discardConsumedLocked(maximum: Int) {
    let discard = min(consumedCount, max(0, maximum))
    guard discard > 0 else { return }
    head = (head + discard) % storage.count
    storedCount -= discard
    startOffset += Int64(discard)
    if storedCount == 0 { head = 0 }
  }

  private func resizeStorageIfPossibleLocked() {
    guard storage.count != capacityLimit, storedCount <= capacityLimit else {
      return
    }
    var replacement = [UInt8](repeating: 0, count: capacityLimit)
    if storedCount > 0 {
      replacement.withUnsafeMutableBytes { destination in
        copyRetainedLocked(into: destination, count: storedCount)
      }
    }
    storage = replacement
    head = 0
  }

  private func copyInLocked(from source: UnsafeRawBufferPointer, count: Int) {
    let storageCount = storage.count
    let tail = (head + storedCount) % storageCount
    let firstCount = min(count, storageCount - tail)
    storage.withUnsafeMutableBytes { destination in
      guard let destinationBase = destination.baseAddress,
            let sourceBase = source.baseAddress else { return }
      destinationBase.advanced(by: tail).copyMemory(
        from: sourceBase,
        byteCount: firstCount
      )
      let secondCount = count - firstCount
      if secondCount > 0 {
        destinationBase.copyMemory(
          from: sourceBase.advanced(by: firstCount),
          byteCount: secondCount
        )
      }
    }
  }

  private func copyOutLocked(
    into destination: UnsafeMutableRawBufferPointer,
    count: Int
  ) {
    let relativeOffset = Int(readOffset - startOffset)
    let sourceIndex = (head + relativeOffset) % storage.count
    let firstCount = min(count, storage.count - sourceIndex)
    storage.withUnsafeBytes { source in
      guard let sourceBase = source.baseAddress,
            let destinationBase = destination.baseAddress else { return }
      destinationBase.copyMemory(
        from: sourceBase.advanced(by: sourceIndex),
        byteCount: firstCount
      )
      let secondCount = count - firstCount
      if secondCount > 0 {
        destinationBase.advanced(by: firstCount).copyMemory(
          from: sourceBase,
          byteCount: secondCount
        )
      }
    }
  }

  private func copyRetainedLocked(
    into destination: UnsafeMutableRawBufferPointer,
    count: Int
  ) {
    let firstCount = min(count, storage.count - head)
    storage.withUnsafeBytes { source in
      guard let sourceBase = source.baseAddress,
            let destinationBase = destination.baseAddress else { return }
      destinationBase.copyMemory(
        from: sourceBase.advanced(by: head),
        byteCount: firstCount
      )
      let secondCount = count - firstCount
      if secondCount > 0 {
        destinationBase.advanced(by: firstCount).copyMemory(
          from: sourceBase,
          byteCount: secondCount
        )
      }
    }
  }
}

private extension NSCondition {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
