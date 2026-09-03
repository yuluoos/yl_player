import Foundation

final class YlNetworkByteSource: NSObject, YlByteSource {
  typealias RetryCallback = (
    _ attempt: Int,
    _ delayMs: Int64,
    _ error: NativePlayerError
  ) -> Void

  private enum Deadline {
    case connect
    case read
  }

  private let recipe: YlNetworkRequestRecipe
  private let policy: YlNetworkRequestPolicy
  private let ring: YlByteRingBuffer
  private let stateLock = NSLock()
  private let timerQueue = DispatchQueue(
    label: "dev.ylplayer.network-byte-source.timers",
    qos: .utility
  )
  private let onRetry: RetryCallback?
  private var session: URLSession!
  private var activeTask: URLSessionDataTask?
  private var ignoredTaskIdentifiers = Set<Int>()
  private var responseAccepted = false
  private var cancelled = false
  private var requestedOffset: Int64 = 0
  private var writeOffset: Int64 = 0
  private var bytesThisAttempt: Int64 = 0
  private var retryCount = 0
  private var metadata: YlNetworkResponseMetadata?
  private var timerGeneration: UInt64 = 0
  private var connectTimer: DispatchSourceTimer?
  private var readTimer: DispatchSourceTimer?
  private var retryTimer: DispatchSourceTimer?

  init(
    recipe: YlNetworkRequestRecipe,
    capacity: Int,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    onRetry: RetryCallback? = nil
  ) {
    self.recipe = recipe
    policy = YlNetworkRequestPolicy(recipe: recipe)
    ring = YlByteRingBuffer(capacity: capacity)
    self.onRetry = onRetry
    super.init()

    let delegateQueue = OperationQueue()
    delegateQueue.name = "dev.ylplayer.network-byte-source.delegate"
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.qualityOfService = .userInitiated
    session = URLSession(
      configuration: sessionConfiguration,
      delegate: self,
      delegateQueue: delegateQueue
    )
    startRequest(offset: 0, validator: nil, resetRetryCount: true)
  }

  var length: Int64? {
    stateLock.withLock { metadata?.resourceLength }
  }

  var supportsRandomAccess: Bool {
    stateLock.withLock { metadata?.supportsRandomAccess ?? false }
  }

  var currentOffset: Int64 { ring.currentOffset }

  var debugBufferedBytes: Int { ring.bufferedBytes }

  var bufferCapacity: Int { ring.capacity }

  var debugActiveTask: URLSessionDataTask? {
    stateLock.withLock { activeTask }
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    try ring.read(into: buffer)
  }

  func seek(to offset: Int64) throws -> Int64 {
    guard offset >= 0 else {
      throw YlByteSourceError.failed(NativePlayerError(
        category: "network",
        code: "network.range_invalid",
        message: "A negative network byte offset is invalid."
      ))
    }
    if ring.seekWithinBuffer(to: offset) { return offset }
    guard supportsRandomAccess else {
      throw YlByteSourceError.failed(NativePlayerError(
        category: "network",
        code: "network.range_not_supported",
        message: "This network source does not support random access."
      ))
    }

    let validator: YlNetworkResponseMetadata? = stateLock.withLock {
      guard !cancelled else { return nil }
      if let task = activeTask {
        ignoredTaskIdentifiers.insert(task.taskIdentifier)
        task.cancel()
      }
      activeTask = nil
      cancelTimersLocked()
      return metadata
    }
    guard !stateLock.withLock({ cancelled }) else {
      throw YlByteSourceError.cancelled
    }
    ring.reset(at: offset)
    startRequest(offset: offset, validator: validator, resetRetryCount: true)
    return offset
  }

  func cancel() {
    let taskAndSession: (URLSessionDataTask?, URLSession?)? = stateLock.withLock {
      guard !cancelled else { return nil }
      cancelled = true
      let values = (activeTask, session)
      activeTask = nil
      cancelTimersLocked()
      return values
    }
    guard let taskAndSession else { return }
    taskAndSession.0?.cancel()
    taskAndSession.1?.invalidateAndCancel()
    ring.cancel()
  }

  func handleMemoryWarning() {
    ring.shrink(to: max(1, ring.capacity / 2))
  }

  private func startRequest(
    offset: Int64,
    validator: YlNetworkResponseMetadata?,
    resetRetryCount: Bool
  ) {
    let request: URLRequest
    do {
      request = try policy.request(offset: offset, validator: validator)
    } catch let error as NativePlayerError {
      ring.fail(error)
      return
    } catch {
      ring.fail(Self.transportError(error))
      return
    }

    let task: URLSessionDataTask? = stateLock.withLock {
      guard !cancelled else { return nil }
      if resetRetryCount { retryCount = 0 }
      requestedOffset = offset
      writeOffset = offset
      bytesThisAttempt = 0
      responseAccepted = false
      let task = session.dataTask(with: request)
      activeTask = task
      armTimerLocked(.connect, milliseconds: recipe.configuration.connectTimeoutMs)
      return task
    }
    task?.resume()
  }

  private func handleAttemptFailure(
    _ error: NativePlayerError,
    transient: Bool,
    taskIdentifier: Int
  ) {
    var retry: (attempt: Int, delay: Int64, offset: Int64,
                validator: YlNetworkResponseMetadata?)?
    var terminalError: NativePlayerError?
    var taskToCancel: URLSessionDataTask?

    stateLock.lock()
    guard !cancelled,
          activeTask?.taskIdentifier == taskIdentifier else {
      stateLock.unlock()
      return
    }
    taskToCancel = activeTask
    ignoredTaskIdentifiers.insert(taskIdentifier)
    activeTask = nil
    cancelTimersLocked()

    let canResume = bytesThisAttempt == 0 || (metadata?.supportsRandomAccess == true)
    if transient && canResume && retryCount < recipe.configuration.maxRetries {
      retryCount += 1
      let delay = retryDelay(millisecondsForAttempt: retryCount)
      retry = (retryCount, delay, writeOffset, metadata)
    } else if transient {
      terminalError = NativePlayerError(
        category: "network",
        code: "network.retry_exhausted",
        message: "Network media retries were exhausted.",
        diagnostic: error.code
      )
    } else {
      terminalError = error
    }
    stateLock.unlock()

    taskToCancel?.cancel()
    if let retry {
      onRetry?(retry.attempt, retry.delay, error)
      scheduleRetry(
        after: retry.delay,
        offset: retry.offset,
        validator: retry.validator
      )
    } else if let terminalError {
      ring.fail(terminalError)
    }
  }

  private func scheduleRetry(
    after delayMs: Int64,
    offset: Int64,
    validator: YlNetworkResponseMetadata?
  ) {
    stateLock.lock()
    guard !cancelled else {
      stateLock.unlock()
      return
    }
    timerGeneration &+= 1
    let generation = timerGeneration
    let timer = DispatchSource.makeTimerSource(queue: timerQueue)
    retryTimer = timer
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let shouldStart = self.stateLock.withLock {
        guard !self.cancelled, self.timerGeneration == generation else {
          return false
        }
        self.retryTimer = nil
        return true
      }
      if shouldStart {
        self.startRequest(
          offset: offset,
          validator: validator,
          resetRetryCount: false
        )
      }
    }
    timer.schedule(deadline: .now() + .milliseconds(Int(delayMs)))
    timer.resume()
    stateLock.unlock()
  }

  private func retryDelay(millisecondsForAttempt attempt: Int) -> Int64 {
    let base = recipe.configuration.baseRetryDelayMs
    let cap = recipe.configuration.maxRetryDelayMs
    guard base > 0, cap > 0 else { return 0 }
    var delay = min(base, cap)
    if attempt > 1 {
      for _ in 1..<attempt {
        if delay >= cap { break }
        delay = min(cap, delay.multipliedReportingOverflow(by: 2).partialValue)
      }
    }
    return max(0, delay)
  }

  private func armTimerLocked(_ deadline: Deadline, milliseconds: Int64) {
    timerGeneration &+= 1
    let generation = timerGeneration
    switch deadline {
    case .connect:
      connectTimer?.cancel()
    case .read:
      readTimer?.cancel()
    }
    let timer = DispatchSource.makeTimerSource(queue: timerQueue)
    timer.setEventHandler { [weak self] in
      self?.deadlineFired(deadline, generation: generation)
    }
    timer.schedule(deadline: .now() + .milliseconds(Int(milliseconds)))
    switch deadline {
    case .connect:
      connectTimer = timer
    case .read:
      readTimer = timer
    }
    timer.resume()
  }

  private func deadlineFired(_ deadline: Deadline, generation: UInt64) {
    let taskIdentifier: Int? = stateLock.withLock {
      guard !cancelled, timerGeneration == generation else { return nil }
      return activeTask?.taskIdentifier
    }
    guard let taskIdentifier else { return }
    let error = NativePlayerError(
      category: "network",
      code: deadline == .connect ? "network.connect_timeout" : "network.read_timeout",
      message: deadline == .connect
        ? "The network connection timed out."
        : "The network media read timed out."
    )
    handleAttemptFailure(error, transient: true, taskIdentifier: taskIdentifier)
  }

  private func cancelTimersLocked() {
    timerGeneration &+= 1
    connectTimer?.cancel()
    readTimer?.cancel()
    retryTimer?.cancel()
    connectTimer = nil
    readTimer = nil
    retryTimer = nil
  }

  private func cancelConnectAndArmRead(taskIdentifier: Int) {
    stateLock.withLock {
      guard activeTask?.taskIdentifier == taskIdentifier, !cancelled else { return }
      timerGeneration &+= 1
      connectTimer?.cancel()
      connectTimer = nil
      armTimerLocked(.read, milliseconds: recipe.configuration.readTimeoutMs)
    }
  }

  private func pauseReadDeadline(taskIdentifier: Int) -> Bool {
    stateLock.withLock {
      guard activeTask?.taskIdentifier == taskIdentifier,
            responseAccepted,
            !cancelled else { return false }
      timerGeneration &+= 1
      readTimer?.cancel()
      readTimer = nil
      return true
    }
  }

  private func resumeReadDeadline(
    taskIdentifier: Int,
    byteCount: Int
  ) -> Int64? {
    stateLock.withLock {
      guard activeTask?.taskIdentifier == taskIdentifier,
            responseAccepted,
            !cancelled else { return nil }
      let added = Int64(byteCount)
      let next = writeOffset.addingReportingOverflow(added)
      guard !next.overflow else { return nil }
      writeOffset = next.partialValue
      bytesThisAttempt += added
      armTimerLocked(.read, milliseconds: recipe.configuration.readTimeoutMs)
      return writeOffset
    }
  }

  private func accept(
    _ received: YlNetworkResponseMetadata,
    taskIdentifier: Int
  ) -> Bool {
    stateLock.withLock {
      guard activeTask?.taskIdentifier == taskIdentifier, !cancelled else {
        return false
      }
      metadata = received
      responseAccepted = true
      return true
    }
  }

  private func isActive(_ taskIdentifier: Int) -> Bool {
    stateLock.withLock {
      !cancelled && activeTask?.taskIdentifier == taskIdentifier
    }
  }

  private static func transportError(_ error: Error) -> NativePlayerError {
    let value = error as NSError
    return NativePlayerError(
      category: "network",
      code: "network.http_status",
      message: "The network media request failed.",
      diagnostic: "\(value.domain) \(value.code)"
    )
  }

  private static func isTransient(_ error: Error) -> Bool {
    guard let code = URLError.Code(rawValue: (error as NSError).code) as URLError.Code?,
          (error as NSError).domain == NSURLErrorDomain else { return false }
    return transientURLErrorCodes.contains(code)
  }

  private static let transientURLErrorCodes: Set<URLError.Code> = [
    .timedOut,
    .cannotFindHost,
    .cannotConnectToHost,
    .networkConnectionLost,
    .dnsLookupFailed,
    .resourceUnavailable,
    .notConnectedToInternet,
    .internationalRoamingOff,
    .callIsActive,
    .dataNotAllowed,
  ]
}

extension YlNetworkByteSource: URLSessionDataDelegate, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard isActive(dataTask.taskIdentifier),
          let response = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      return
    }

    if YlNetworkRequestPolicy.isRetryableStatus(response.statusCode) {
      let error = NativePlayerError(
        category: "network",
        code: "network.http_status",
        message: "The server returned a retryable HTTP status.",
        diagnostic: "HTTP \(response.statusCode)"
      )
      handleAttemptFailure(error, transient: true, taskIdentifier: dataTask.taskIdentifier)
      completionHandler(.cancel)
      return
    }

    do {
      let received = try policy.validate(
        response: response,
        requestedOffset: stateLock.withLock { requestedOffset }
      )
      guard accept(received, taskIdentifier: dataTask.taskIdentifier) else {
        completionHandler(.cancel)
        return
      }
      completionHandler(.allow)
      if received.isEOF {
        ring.finish()
      } else {
        cancelConnectAndArmRead(taskIdentifier: dataTask.taskIdentifier)
      }
    } catch let error as NativePlayerError {
      handleAttemptFailure(error, transient: false, taskIdentifier: dataTask.taskIdentifier)
      completionHandler(.cancel)
    } catch {
      handleAttemptFailure(
        Self.transportError(error),
        transient: false,
        taskIdentifier: dataTask.taskIdentifier
      )
      completionHandler(.cancel)
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    guard !data.isEmpty,
          pauseReadDeadline(taskIdentifier: dataTask.taskIdentifier) else { return }
    let offset = stateLock.withLock { writeOffset }
    do {
      try ring.write(data, at: offset)
      guard resumeReadDeadline(
        taskIdentifier: dataTask.taskIdentifier,
        byteCount: data.count
      ) != nil else {
        handleAttemptFailure(
          NativePlayerError(
            category: "network",
            code: "network.range_invalid",
            message: "The network byte offset overflowed."
          ),
          transient: false,
          taskIdentifier: dataTask.taskIdentifier
        )
        return
      }
    } catch YlByteSourceError.cancelled {
      return
    } catch let YlByteSourceError.failed(error) {
      handleAttemptFailure(error, transient: false, taskIdentifier: dataTask.taskIdentifier)
    } catch {
      handleAttemptFailure(
        Self.transportError(error),
        transient: false,
        taskIdentifier: dataTask.taskIdentifier
      )
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let ignored: Bool = stateLock.withLock {
      ignoredTaskIdentifiers.remove(task.taskIdentifier) != nil
    }
    if ignored { return }
    guard isActive(task.taskIdentifier) else { return }
    if let error {
      handleAttemptFailure(
        Self.transportError(error),
        transient: Self.isTransient(error),
        taskIdentifier: task.taskIdentifier
      )
      return
    }
    stateLock.withLock {
      guard activeTask?.taskIdentifier == task.taskIdentifier else { return }
      activeTask = nil
      cancelTimersLocked()
    }
    ring.finish()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let sourceURL = task.currentRequest?.url,
          let destinationURL = request.url else {
      completionHandler(nil)
      handleAttemptFailure(
        NativePlayerError(
          category: "network",
          code: "network.invalid_redirect",
          message: "The network redirect destination was invalid."
        ),
        transient: false,
        taskIdentifier: task.taskIdentifier
      )
      return
    }
    do {
      completionHandler(try policy.redirectRequest(
        from: sourceURL,
        response: response,
        to: destinationURL
      ))
    } catch let error as NativePlayerError {
      completionHandler(nil)
      handleAttemptFailure(error, transient: false, taskIdentifier: task.taskIdentifier)
    } catch {
      completionHandler(nil)
      handleAttemptFailure(
        Self.transportError(error),
        transient: false,
        taskIdentifier: task.taskIdentifier
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
