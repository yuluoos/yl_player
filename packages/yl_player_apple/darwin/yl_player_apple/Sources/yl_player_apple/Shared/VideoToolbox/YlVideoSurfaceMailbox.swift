import CoreVideo
import Foundation

/// Coalesces producers onto the main queue without blocking a demux/seek queue.
/// An epoch invalidates both queued frames and errors from the old render work.
final class YlVideoSurfaceMailbox {
  struct Frame {
    let pixelBuffer: CVPixelBuffer
    let reservation: AnyObject?
  }
  private let lock = NSLock()
  private let schedule: (@escaping () -> Void) -> Void
  private var epoch: UInt64 = 0
  private var pending: Frame?
  private var needsClear = false
  private var scheduled = false
  private var disposed = false
  var consume: ((Frame?, Bool, Bool, UInt64) -> Void)?

  init(schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
    self.schedule = schedule
  }

  func publish(_ frame: Frame) {
    update { if !disposed { pending = frame } }
  }
  func clear() {
    update {
      epoch &+= 1
      pending = nil
      needsClear = true
    }
  }
  func dispose() {
    update {
      epoch &+= 1
      disposed = true
      pending = nil
      needsClear = true
    }
  }
  func accepts(_ epoch: UInt64) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return !disposed && self.epoch == epoch
  }

  private func update(_ mutation: () -> Void) {
    lock.lock()
    mutation()
    let enqueue = !scheduled
    scheduled = true
    lock.unlock()
    if enqueue { schedule { [weak self] in self?.drain() } }
  }

  private func drain() {
    lock.lock()
    let frame = pending
    let clear = needsClear
    let disposed = disposed
    let epoch = epoch
    pending = nil
    needsClear = false
    scheduled = false
    lock.unlock()
    consume?(frame, clear, disposed, epoch)
  }
}
