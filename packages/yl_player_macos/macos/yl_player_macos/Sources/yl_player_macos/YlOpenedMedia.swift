import Darwin
import Foundation
import YlFFmpegBridge

enum YlFallbackSourceRecipe {
  case local(path: String, container: YlFallbackContainer)
  case network(request: YlNetworkRequestRecipe, container: YlFallbackContainer)

  var container: YlFallbackContainer {
    switch self {
    case let .local(_, container), let .network(_, container):
      return container
    }
  }
}

private final class YlByteSourceCallbackBox {
  let source: YlByteSource
  private let lock = NSLock()
  private var storedError: NativePlayerError?
  private var operationToken: YlOpenCancellationToken?

  init(source: YlByteSource) {
    self.source = source
  }

  var opaque: UnsafeMutableRawPointer {
    Unmanaged.passUnretained(self).toOpaque()
  }

  var lastError: NativePlayerError? {
    lock.withLock { storedError }
  }

  func remember(_ error: NativePlayerError) {
    lock.withLock { storedError = error }
  }

  var isOperationCancelled: Bool {
    lock.withLock { operationToken?.isCancelled ?? false }
  }

  func beginOperation(_ token: YlOpenCancellationToken?) {
    lock.withLock {
      operationToken = token
      storedError = nil
    }
  }

  func endOperation() {
    lock.withLock {
      operationToken = nil
      if storedError?.code == "network.cancelled" { storedError = nil }
    }
  }
}

private func ylByteSourceBox(
  _ opaque: UnsafeMutableRawPointer?
) -> YlByteSourceCallbackBox? {
  guard let opaque else { return nil }
  return Unmanaged<YlByteSourceCallbackBox>.fromOpaque(opaque).takeUnretainedValue()
}

private func ylByteSourceRead(
  _ opaque: UnsafeMutableRawPointer?,
  _ buffer: UnsafeMutablePointer<UInt8>?,
  _ capacity: Int32
) -> Int32 {
  guard let box = ylByteSourceBox(opaque),
        let buffer,
        capacity > 0 else { return Int32(YLFCallbackError) }
  if box.isOperationCancelled { return Int32(YLFCallbackCancelled) }
  do {
    let count = try box.source.read(into: UnsafeMutableRawBufferPointer(
      start: buffer,
      count: Int(capacity)
    ))
    guard count >= 0, count <= Int(capacity) else {
      return Int32(YLFCallbackError)
    }
    return Int32(count)
  } catch YlByteSourceError.cancelled {
    return Int32(YLFCallbackCancelled)
  } catch let YlByteSourceError.failed(error) {
    box.remember(error)
    return Int32(YLFCallbackError)
  } catch {
    box.remember(NativePlayerError(
      category: "network",
      code: "network.http_status",
      message: "The network media byte source failed.",
      diagnostic: String(describing: type(of: error))
    ))
    return Int32(YLFCallbackError)
  }
}

private func ylByteSourceSeek(
  _ opaque: UnsafeMutableRawPointer?,
  _ offset: Int64,
  _ whence: Int32
) -> Int64 {
  guard let box = ylByteSourceBox(opaque) else {
    return Int64(YLFCallbackError)
  }
  if box.isOperationCancelled { return Int64(YLFCallbackCancelled) }
  let avSeekSize: Int32 = 0x10000
  let avSeekForce: Int32 = 0x20000
  let origin = whence & ~avSeekForce
  if origin == avSeekSize {
    return box.source.length ?? Int64(YLFCallbackSeekUnsupported)
  }

  let base: Int64
  switch origin {
  case SEEK_SET:
    base = 0
  case SEEK_CUR:
    base = box.source.currentOffset
  case SEEK_END:
    guard let length = box.source.length else {
      return Int64(YLFCallbackSeekUnsupported)
    }
    base = length
  default:
    return Int64(YLFCallbackSeekUnsupported)
  }
  let target = base.addingReportingOverflow(offset)
  guard !target.overflow, target.partialValue >= 0 else {
    return Int64(YLFCallbackError)
  }
  do {
    return try box.source.seek(to: target.partialValue)
  } catch YlByteSourceError.cancelled {
    return Int64(YLFCallbackCancelled)
  } catch let YlByteSourceError.failed(error) {
    box.remember(error)
    return error.code == "network.range_not_supported"
      ? Int64(YLFCallbackSeekUnsupported)
      : Int64(YLFCallbackError)
  } catch {
    return Int64(YLFCallbackError)
  }
}

private func ylByteSourceCancel(_ opaque: UnsafeMutableRawPointer?) {
  ylByteSourceBox(opaque)?.source.cancel()
}

final class YlOpenedMedia {
  let recipe: YlFallbackSourceRecipe?
  let info: YLFMediaInfo
  private let lock = NSLock()
  private let contextOperationLock = NSLock()
  private var callbackBox: YlByteSourceCallbackBox?
  private var ownedContext: YLFMediaContextRef?

  var context: YLFMediaContextRef? {
    lock.withLock { ownedContext }
  }

  var supportsRandomAccess: Bool {
    lock.withLock {
      if let source = callbackBox?.source { return source.supportsRandomAccess }
      if case .network = recipe { return false }
      return true
    }
  }

  var lastInputError: NativePlayerError? {
    lock.withLock { callbackBox?.lastError }
  }

  convenience init(
    recipe: YlFallbackSourceRecipe,
    networkBufferBytes: Int = 8 * 1024 * 1024,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    onRetry: YlNetworkByteSource.RetryCallback? = nil,
    onSourceCreated: ((YlByteSource) -> Void)? = nil
  ) throws {
    switch recipe {
    case let .local(path, container):
      var context: YLFMediaContextRef?
      var info = YLFMediaInfo()
      let result = path.withCString { ylf_open_local($0, &context, &info) }
      guard result == Int32(YLFResultOK), context != nil else {
        throw Self.openError(
          result: result,
          callbackError: nil,
          network: false,
          container: container
        )
      }
      self.init(context: context, info: info, box: nil, recipe: recipe)

    case let .network(request, _):
      let source = YlNetworkByteSource(
        recipe: request,
        capacity: networkBufferBytes,
        sessionConfiguration: sessionConfiguration,
        onRetry: onRetry
      )
      onSourceCreated?(source)
      try self.init(byteSource: source, recipe: recipe)
    }
  }

  convenience init(byteSource: YlByteSource) throws {
    try self.init(byteSource: byteSource, recipe: nil, container: .matroska)
  }

  private convenience init(
    byteSource: YlByteSource,
    recipe: YlFallbackSourceRecipe?,
    container: YlFallbackContainer? = nil
  ) throws {
    let box = YlByteSourceCallbackBox(source: byteSource)
    var context: YLFMediaContextRef?
    var info = YLFMediaInfo()
    let result = ylf_open_callbacks(
      box.opaque,
      ylByteSourceRead,
      ylByteSourceSeek,
      ylByteSourceCancel,
      &context,
      &info
    )
    guard result == Int32(YLFResultOK), context != nil else {
      throw Self.openError(
        result: result,
        callbackError: box.lastError,
        network: true,
        container: container ?? recipe?.container ?? .matroska
      )
    }
    self.init(context: context, info: info, box: box, recipe: recipe)
  }

  private init(
    context: YLFMediaContextRef?,
    info: YLFMediaInfo,
    box: YlByteSourceCallbackBox?,
    recipe: YlFallbackSourceRecipe?
  ) {
    ownedContext = context
    self.info = info
    callbackBox = box
    self.recipe = recipe
  }

  @discardableResult
  func seek(toMediaTimeUs positionUs: Int64) throws -> Int64 {
    try contextOperationLock.withLock {
      let (context, box) = lock.withLock { (ownedContext, callbackBox) }
      guard let context else {
        throw NativePlayerError(
          category: "internal",
          code: "internal.fallback_invariant",
          message: "The Matroska media input is closed."
        )
      }
      if box?.isOperationCancelled == true {
        throw YlOpenCancellationToken.cancellationError()
      }
      let result = ylf_seek(context, positionUs)
      guard result == Int32(YLFResultOK) else {
        if let error = box?.lastError { throw error }
        if result == Int32(YLFResultCallbackCancelled) {
          throw YlOpenCancellationToken.cancellationError()
        }
        if result == Int32(YLFResultCallbackSeekUnsupported) {
          throw NativePlayerError(
            category: "network",
            code: "network.range_not_supported",
            message: "This network source does not support random access."
          )
        }
        throw NativePlayerError(
          category: "container",
          code: "container.mkv_seek_failed",
          message: "The Matroska media could not be seeked.",
          diagnostic: "YlFFmpegBridge result \(result)"
        )
      }
      return positionUs
    }
  }

  func cancelInput() {
    let source = lock.withLock { callbackBox?.source }
    source?.cancel()
  }

  func interruptRead() {
    let source = lock.withLock { callbackBox?.source }
    source?.interruptRead()
  }

  func beginControlOperation(_ token: YlOpenCancellationToken?) {
    lock.withLock { callbackBox }?.beginOperation(token)
  }

  func endControlOperation() {
    lock.withLock { callbackBox }?.endOperation()
  }

  func resumeReads() {
    let source = lock.withLock { callbackBox?.source }
    source?.resumeReads()
  }

  func handleMemoryWarning() {
    let source = lock.withLock { callbackBox?.source }
    source?.handleMemoryWarning()
  }

  func close() {
    contextOperationLock.withLock {
      let values: (YLFMediaContextRef?, YlByteSourceCallbackBox?)? = lock.withLock {
        guard ownedContext != nil else { return nil }
        let values = (ownedContext, callbackBox)
        ownedContext = nil
        return values
      }
      guard let rawContext = values?.0 else { return }
      var context: YLFMediaContextRef? = rawContext
      let retainedBox = values?.1
      ylf_close(&context)
      withExtendedLifetime(retainedBox) {}
      lock.withLock { callbackBox = nil }
    }
  }

  deinit {
    close()
  }

  private static func openError(
    result: Int32,
    callbackError: NativePlayerError?,
    network: Bool,
    container: YlFallbackContainer
  ) -> NativePlayerError {
    if let callbackError { return callbackError }
    if result == Int32(YLFResultCallbackCancelled) {
      return NativePlayerError(
        category: "cancelled",
        code: "network.cancelled",
        message: "The network media open was cancelled."
      )
    }
    switch container {
    case .flv:
      return NativePlayerError(
        category: "container",
        code: result == Int32(YLFResultUnsupportedContainer)
          ? "container.flv_malformed" : "container.flv_open_failed",
        message: "The FLV media could not be opened.",
        diagnostic: "YlFFmpegBridge result \(result)"
      )
    case .matroska:
      return NativePlayerError(
        category: result == Int32(YLFResultUnsupportedContainer)
          ? "container" : (network ? "network" : "container"),
        code: result == Int32(YLFResultUnsupportedContainer)
          ? "container.mkv_malformed"
          : (network ? "network.http_status" : "container.mkv_open_failed"),
        message: network
          ? "The network Matroska media could not be opened."
          : "The local Matroska file could not be opened.",
        diagnostic: "YlFFmpegBridge result \(result)"
      )
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
