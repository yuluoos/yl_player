import AVFoundation
import Foundation
import YlFFmpegBridge

protocol YlRecoveryScheduling {
  func schedule(_ workItem: DispatchWorkItem, afterMilliseconds delayMs: Int64)
}
struct YlDispatchRecoveryScheduler: YlRecoveryScheduling {
  let queue: DispatchQueue
  func schedule(_ workItem: DispatchWorkItem, afterMilliseconds delayMs: Int64) {
    queue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: workItem)
  }
}
protocol YlRecoverySession: AnyObject {
  var recoveryGeneration: UInt64 { get }
  var managedRequestFailure: NativePlayerError? { get }
  func mayScheduleRecovery(generation: UInt64) -> Bool
  func emitRecoveryRetry(attempt: Int, delayMs: Int64, error: NativePlayerError, generation: UInt64)
  func installRecoveryWorkItem(_ workItem: DispatchWorkItem, generation: UInt64) -> Bool
  func beginRecoveryOpen(_ token: YlOpenCancellationToken, generation: UInt64) -> Bool
  func makeLiveReconnectPipeline(generation: UInt64, cancellationToken: YlOpenCancellationToken) throws -> YlFallbackReconnectPipeline
  func installRecoveryCandidate(_ candidate: YlFallbackReconnectPipeline, token: YlOpenCancellationToken, generation: UInt64) -> Bool
  func resumeRecovery(generation: UInt64)
  func shouldRetryRecovery(token: YlOpenCancellationToken, generation: UInt64) -> Bool
  func reportRecoveryExhaustion(_ error: NativePlayerError, generation: UInt64)
}

struct YlFallbackReconnectPipeline {
  let media: YlDemuxPipeline.Resource
  let info: YLFMediaInfo
  let videoStream: YLFStreamInfo
  let audioStreams: [YLFStreamInfo]
  let audioCookies: [Int32: Data]
  let selectedAudioStream: YLFStreamInfo?
  let decoder: YlVideoPipeline.Resource
  let audioRenderer: YlAudioPipeline.Resource

  func discard() {
    decoder.dispose()
    audioRenderer.dispose()
    media.cancelInput()
    media.close()
  }
}

/// Owns retry budget, scheduled reopen work and first-frame recovery accounting.
/// Every asynchronous continuation carries the immutable operation generation.
final class YlRecoveryCoordinator {
  weak var session: (any YlRecoverySession)?
  private let scheduler: any YlRecoveryScheduling
  private let liveReconnectController: YlLiveReconnectController
  private var reconnectWorkItem: DispatchWorkItem?
  private var awaitingReconnectFirstFrame = false
  private(set) var reconnectCount = 0

  init(configuration: YlNetworkConfiguration, scheduler: any YlRecoveryScheduling) {
    self.scheduler = scheduler
    self.liveReconnectController = YlLiveReconnectController(configuration: configuration)
  }

  struct ScheduledWork {
    private let item: DispatchWorkItem
    fileprivate init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
  }
  func detachScheduledWork() -> ScheduledWork? {
    let work = reconnectWorkItem
    reconnectWorkItem = nil
    return work.map(ScheduledWork.init)
  }
  func replaceScheduledWork(_ work: DispatchWorkItem) {
    reconnectWorkItem?.cancel()
    reconnectWorkItem = work
  }
  func beginReopen() { reconnectWorkItem = nil }
  func cancelBudget() { liveReconnectController.cancel() }
  func mayInstall(generation: UInt64, currentGeneration: UInt64) -> Bool {
    liveReconnectController.shouldInstall(reconnectGeneration: generation, currentGeneration: currentGeneration)
  }
  func resetAfterStop() { reconnectCount = 0; awaitingReconnectFirstFrame = false }
  func clearFirstFrameExpectation() { awaitingReconnectFirstFrame = false }
  func expectFirstFrame() { awaitingReconnectFirstFrame = true }
  func acceptFirstFrame(isCurrent: Bool) -> Bool {
    guard awaitingReconnectFirstFrame, isCurrent else { return false }
    awaitingReconnectFirstFrame = false
    reconnectCount += 1
    return true
  }
  func markFirstFrame() { liveReconnectController.markFirstFrame() }

  func scheduleLiveReconnect(after error: NativePlayerError, generation reconnectGeneration: UInt64) {
    guard let session, session.mayScheduleRecovery(generation: reconnectGeneration) else { return }
    if let terminal = session.managedRequestFailure {
      session.reportRecoveryExhaustion(terminal, generation: reconnectGeneration)
      return
    }
    guard let delayMs = liveReconnectController.nextDelayMs() else {
      finishLiveReconnectExhausted(error, generation: reconnectGeneration)
      return
    }
    let attempt = liveReconnectController.attempt
    DispatchQueue.main.async { [weak self] in
      self?.session?.emitRecoveryRetry(attempt: attempt, delayMs: delayMs,
        error: error, generation: reconnectGeneration)
    }
    let workItem = DispatchWorkItem { [weak self] in
      self?.performLiveReconnect(generation: reconnectGeneration)
    }
    let installed = session.installRecoveryWorkItem(workItem, generation: reconnectGeneration)
    guard installed else { return }
    scheduler.schedule(workItem, afterMilliseconds: delayMs)
  }

  private func performLiveReconnect(generation reconnectGeneration: UInt64) {
    guard let session, liveReconnectController.shouldInstall(
      reconnectGeneration: reconnectGeneration, currentGeneration: session.recoveryGeneration
    ) else { return }
    let token = YlOpenCancellationToken()
    let mayOpen = session.beginRecoveryOpen(token, generation: reconnectGeneration)
    guard mayOpen else { return }
    do {
      let candidate = try session.makeLiveReconnectPipeline(generation: reconnectGeneration, cancellationToken: token)
      try token.throwIfCancelled()
      let installed = session.installRecoveryCandidate(candidate, token: token, generation: reconnectGeneration)
      guard installed else { candidate.discard(); return }
      session.resumeRecovery(generation: reconnectGeneration)
    } catch let error as NativePlayerError {
      let shouldRetry = session.shouldRetryRecovery(token: token, generation: reconnectGeneration)
      if shouldRetry { scheduleLiveReconnect(after: error, generation: reconnectGeneration) }
    } catch {
      let shouldRetry = session.shouldRetryRecovery(token: token, generation: reconnectGeneration)
      if shouldRetry {
        scheduleLiveReconnect(after: NativePlayerError(category: "network", code: "network.http_status",
          message: "The HTTP-FLV reconnect failed.", diagnostic: YlAppleSafeDiagnostics.diagnostic(error)),
          generation: reconnectGeneration)
      }
    }
  }

  private func finishLiveReconnectExhausted(_ lastError: NativePlayerError, generation reconnectGeneration: UInt64) {
    DispatchQueue.main.async { [weak self] in
      guard let session = self?.session else { return }
      session.reportRecoveryExhaustion(NativePlayerError(
        category: "network",
        code: "network.retry_exhausted",
        message: "HTTP-FLV reconnect attempts were exhausted.",
        diagnostic: lastError.code
      ), generation: reconnectGeneration)
    }
  }
}
