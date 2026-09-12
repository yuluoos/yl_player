import Foundation

private protocol YlHlsResourceLoading: AnyObject {
  func load(_ url: URL, maximumBytes: Int) throws -> Data
  func interruptRead()
  func resumeReads()
  func cancel()
}

private final class YlClosureHlsResourceLoader: YlHlsResourceLoading {
  let loadClosure: (URL) throws -> Data
  init(load: @escaping (URL) throws -> Data) { loadClosure = load }
  func load(_ url: URL, maximumBytes: Int) throws -> Data {
    let data = try loadClosure(url)
    guard data.count <= maximumBytes else {
      throw YlByteSourceError.failed(YlHlsSegmentByteSource.resourceTooLarge())
    }
    return data
  }
  func interruptRead() {}
  func resumeReads() {}
  func cancel() {}
}

private final class YlNetworkHlsResourceLoader: YlHlsResourceLoading {
  private let template: YlNetworkRequestRecipe
  private let capacity: Int
  private let sessionConfiguration: URLSessionConfiguration
  private let onRetry: YlNetworkByteSource.RetryCallback?
  private let lock = NSLock()
  private var active: YlNetworkByteSource?
  private var interrupted = false
  private var cancelled = false

  init(template: YlNetworkRequestRecipe, capacity: Int,
       sessionConfiguration: URLSessionConfiguration,
       onRetry: YlNetworkByteSource.RetryCallback?) {
    self.template = template
    self.capacity = max(64 * 1024, capacity)
    self.sessionConfiguration = sessionConfiguration
    self.onRetry = onRetry
  }

  func load(_ url: URL, maximumBytes: Int) throws -> Data {
    let source = YlNetworkByteSource(
      recipe: YlNetworkRequestRecipe(
        url: url,
        headers: template.headers,
        credentials: template.credentials,
        credentialContext: template.credentialContext,
        configuration: template.configuration,
        mode: .sequentialLive,
        managedIntent: template.managedIntent,
        bufferScope: template.bufferScope
      ),
      capacity: min(capacity, maximumBytes),
      sessionConfiguration: sessionConfiguration,
      onRetry: onRetry
    )
    let state = lock.withLock { () -> (cancelled: Bool, interrupted: Bool) in
      if !cancelled { active = source }
      return (cancelled, interrupted)
    }
    if state.cancelled {
      source.cancel()
      throw YlByteSourceError.cancelled
    }
    if state.interrupted { source.interruptRead() }
    defer {
      source.cancel()
      lock.withLock { if active === source { active = nil } }
    }

    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = try buffer.withUnsafeMutableBytes { try source.read(into: $0) }
      if count == 0 { return result }
      guard result.count <= maximumBytes - count else {
        throw YlByteSourceError.failed(YlHlsSegmentByteSource.resourceTooLarge())
      }
      result.append(contentsOf: buffer.prefix(count))
    }
  }

  func interruptRead() {
    let source = lock.withLock { interrupted = true; return active }
    source?.interruptRead()
  }

  func resumeReads() {
    let source = lock.withLock { interrupted = false; return active }
    source?.resumeReads()
  }

  func cancel() {
    let source = lock.withLock { cancelled = true; return active }
    source?.cancel()
  }
}

final class YlHlsSegmentByteSource: YlMediaTimeSeekableByteSource {
  static let maximumManifestBytes = 2 * 1024 * 1024
  static let maximumSegmentBytes = 64 * 1024 * 1024

  let playlist: YlHlsMediaPlaylist
  private let loader: YlHlsResourceLoading
  private let lock = NSLock()
  private var segmentIndex = 0
  private var segmentData = Data()
  private var segmentOffset = 0
  private var deliveredBytes: Int64 = 0
  private var interrupted = false
  private var cancelled = false

  convenience init(
    playlist: YlHlsMediaPlaylist,
    load: @escaping (URL) throws -> Data
  ) {
    self.init(playlist: playlist, loader: YlClosureHlsResourceLoader(load: load))
  }

  convenience init(
    request: YlNetworkRequestRecipe,
    capacity: Int,
    sessionConfiguration: URLSessionConfiguration,
    onRetry: YlNetworkByteSource.RetryCallback?
  ) throws {
    let loader = YlNetworkHlsResourceLoader(
      template: request,
      capacity: capacity,
      sessionConfiguration: sessionConfiguration,
      onRetry: onRetry
    )
    let manifest = try loader.load(
      request.url,
      maximumBytes: Self.maximumManifestBytes
    )
    let playlist = try YlHlsMediaPlaylist.parse(
      data: manifest,
      baseURL: request.url
    )
    self.init(playlist: playlist, loader: loader)
  }

  private init(playlist: YlHlsMediaPlaylist, loader: YlHlsResourceLoading) {
    self.playlist = playlist
    self.loader = loader
  }

  var length: Int64? { nil }
  var supportsRandomAccess: Bool { true }
  var currentOffset: Int64 { lock.withLock { deliveredBytes } }
  var durationUs: Int64 { playlist.durationUs }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    guard buffer.count > 0 else { return 0 }
    var written = 0
    while written < buffer.count {
      let action = try lock.withLock { () -> (index: Int, url: URL)? in
        if cancelled { throw YlByteSourceError.cancelled }
        if interrupted { throw YlByteSourceError.cancelled }
        if segmentOffset < segmentData.count { return nil }
        guard segmentIndex < playlist.segments.count else { return nil }
        return (segmentIndex, playlist.segments[segmentIndex].url)
      }
      if let action {
        let data = try loader.load(
          action.url,
          maximumBytes: Self.maximumSegmentBytes
        )
        try lock.withLock {
          if cancelled || interrupted { throw YlByteSourceError.cancelled }
          guard action.index == segmentIndex else { return }
          segmentData = data
          segmentOffset = 0
          segmentIndex += 1
        }
        continue
      }

      let copied = lock.withLock { () -> Int in
        guard segmentOffset < segmentData.count else { return 0 }
        let count = min(buffer.count - written, segmentData.count - segmentOffset)
        segmentData.copyBytes(
          to: UnsafeMutableRawBufferPointer(rebasing: buffer[written..<(written + count)]),
          from: segmentOffset..<(segmentOffset + count)
        )
        segmentOffset += count
        deliveredBytes += Int64(count)
        return count
      }
      if copied == 0 { return written }
      written += copied
    }
    return written
  }

  func seek(to offset: Int64) throws -> Int64 {
    guard offset == currentOffset else {
      throw YlByteSourceError.failed(NativePlayerError(
        category: "network",
        code: "network.range_not_supported",
        message: "Managed HLS supports timeline seeking instead of byte ranges."
      ))
    }
    return offset
  }

  func seek(toMediaTimeUs positionUs: Int64) throws -> Int64 {
    let index = playlist.segmentIndex(containing: positionUs)
    let startUs = playlist.segments[index].startUs
    try lock.withLock {
      if cancelled { throw YlByteSourceError.cancelled }
      segmentIndex = index
      segmentData.removeAll(keepingCapacity: false)
      segmentOffset = 0
      deliveredBytes = 0
    }
    return startUs
  }

  func interruptRead() {
    lock.withLock { interrupted = true }
    loader.interruptRead()
  }

  func resumeReads() {
    lock.withLock { interrupted = false }
    loader.resumeReads()
  }

  func cancel() {
    let shouldCancel = lock.withLock { () -> Bool in
      guard !cancelled else { return false }
      cancelled = true
      return true
    }
    if shouldCancel { loader.cancel() }
  }

  func handleMemoryWarning() {}

  static func resourceTooLarge() -> NativePlayerError {
    NativePlayerError(
      category: "resource",
      code: "resource.hls_resource_too_large",
      message: "The managed HLS resource exceeded its memory limit."
    )
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
