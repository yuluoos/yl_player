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
  private let managedTransportFactory: YlManagedHTTPTransport.Factory?
  private var managedTransport: YlManagedHTTPTransport?
  private var managedIdentifier: Int?
  private var nextManagedIdentifier = -1
  private var currentTaskIdentifier: Int? { managedIdentifier ?? activeTask?.taskIdentifier }
  private let managedPolicy: YlManagedRequestPolicy
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

  init(
    recipe: YlNetworkRequestRecipe,
    capacity: Int,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    onRetry: RetryCallback? = nil,
    managedPolicy: YlManagedRequestPolicy = YlManagedRequestPolicy(),
    managedTransportFactory: YlManagedHTTPTransport.Factory? = YlManagedHTTPTransport.make
  ) {
    self.recipe = recipe
    self.managedPolicy = managedPolicy
    self.managedTransportFactory = managedTransportFactory
    policy = YlNetworkRequestPolicy(recipe: recipe)
    ring = YlByteRingBuffer(capacity: capacity, bufferScope: recipe.bufferScope)
    self.onRetry = onRetry
    super.init()

    let delegateQueue = OperationQueue()
    delegateQueue.name = "dev.ylplayer.network-byte-source.delegate"
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.qualityOfService = .userInitiated
    let ownedConfiguration = sessionConfiguration.copy() as! URLSessionConfiguration
    ownedConfiguration.httpShouldSetCookies = false
    ownedConfiguration.httpCookieStorage = nil
    ownedConfiguration.urlCredentialStorage = nil
    if recipe.managedIntent != nil {
      ownedConfiguration.timeoutIntervalForRequest = .greatestFiniteMagnitude
      ownedConfiguration.timeoutIntervalForResource = .greatestFiniteMagnitude
    }
    session = URLSession(
      configuration: ownedConfiguration,
      delegate: self,
      delegateQueue: delegateQueue
    )
    if recipe.managedIntent != nil, managedTransportFactory != nil,
       let proxy = ownedConfiguration.connectionProxyDictionary, !proxy.isEmpty {
      let error = YlManagedHTTPTransport.unsupported()
      recipe.managedIntent?.fail(error); ring.fail(error)
    } else { startRequest(offset: 0, validator: nil, resetRetryCount: true) }
  }

  var length: Int64? {
    stateLock.withLock { metadata?.resourceLength }
  }

  var supportsRandomAccess: Bool {
    guard recipe.mode == .randomAccessVOD else { return false }
    return stateLock.withLock { metadata?.supportsRandomAccess ?? false }
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
    if recipe.mode == .sequentialLive, offset != 0 {
      throw YlByteSourceError.failed(NativePlayerError(
        category: "network",
        code: "network.range_not_supported",
        message: "This live network source does not support random access."
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
      managedTransport?.cancel(); managedTransport = nil; managedIdentifier = nil
      cancelTimersLocked()
      ring.reset(at: offset)
      return metadata
    }
    guard !stateLock.withLock({ cancelled }) else {
      throw YlByteSourceError.cancelled
    }
    startRequest(offset: offset, validator: validator, resetRetryCount: true)
    return offset
  }

  func cancel() {
    let taskAndSession: (URLSessionDataTask?, URLSession?)? = stateLock.withLock {
      guard !cancelled else { return nil }
      cancelled = true
      let values = (activeTask, session)
      activeTask = nil
      managedTransport?.cancel(); managedTransport = nil; managedIdentifier = nil
      cancelTimersLocked()
      return values
    }
    guard let taskAndSession else { return }
    taskAndSession.0?.cancel()
    taskAndSession.1?.invalidateAndCancel()
    ring.cancel()
  }

  func interruptRead() {
    ring.interruptRead()
  }

  func resumeReads() {
    ring.resumeReads()
  }

  func handleMemoryWarning() {
    ring.shrink(to: min(ring.capacity, 2 * 1024 * 1024))
  }

  private func startRequest(
    offset: Int64,
    validator: YlNetworkResponseMetadata?,
    resetRetryCount: Bool,
    expectedGeneration: UInt64? = nil
  ) {
    var failure: NativePlayerError?
    var managedToStart: YlManagedHTTPTransport?
    let task: URLSessionDataTask? = stateLock.withLock {
      guard !cancelled, expectedGeneration == nil || expectedGeneration == timerGeneration else { return nil }
      if let terminal = recipe.managedIntent?.terminalFailure { failure = terminal; return nil }
      do {
        let request = try policy.request(offset: offset, validator: validator)
        if resetRetryCount { retryCount = 0 }
        requestedOffset = offset
        writeOffset = offset
        bytesThisAttempt = 0
        responseAccepted = false
        if recipe.managedIntent != nil, managedTransportFactory != nil {
          managedToStart = try installManagedRequestLocked(request)
          return nil
        }
        let task = session.dataTask(with: request)
        activeTask = task
        armTimerLocked(.connect, milliseconds: recipe.configuration.connectTimeoutMs)
        return task
      } catch let error as NativePlayerError { failure = error }
      catch { failure = Self.transportError(error) }
      return nil
    }
    if let failure { recipe.managedIntent?.fail(failure); ring.fail(failure) }
    managedToStart?.start()
    task?.resume()
  }

  private func installManagedRequestLocked(_ request: URLRequest) throws -> YlManagedHTTPTransport {
    let identifier = nextManagedIdentifier
    nextManagedIdentifier &-= 1
    let transport = try managedTransportFactory!(request) { [weak self] event in
      self?.receiveManaged(event, identifier: identifier, requestURL: request.url!)
    }
    try transport.assignBufferScope(recipe.bufferScope)
    managedTransport?.cancel()
    managedTransport = transport
    managedIdentifier = identifier
    activeTask = nil
    responseAccepted = false
    cancelTimersLocked()
    armTimerLocked(.connect, milliseconds: recipe.configuration.connectTimeoutMs)
    return transport
  }

  private func receiveManaged(_ event: YlManagedHTTPTransport.Event, identifier: Int, requestURL: URL) {
    guard isActive(identifier) else { return }
    switch event {
    case .headers(let response):
      if [301, 302, 303, 307, 308].contains(response.statusCode) {
        do {
          guard let location = response.value(forHTTPHeaderField: "Location"),
                let destination = URL(string: location, relativeTo: requestURL)?.absoluteURL else {
            throw YlHTTPResponseParser.invalid("network.invalid_redirect")
          }
          let request = try policy.redirectRequest(from: requestURL, response: response, to: destination)
          let next = try stateLock.withLock { () -> YlManagedHTTPTransport? in
            guard !cancelled, currentTaskIdentifier == identifier else { return nil }
            return try installManagedRequestLocked(request)
          }
          next?.start()
        } catch {
          handleAttemptFailure(error as? NativePlayerError ?? Self.transportError(error), transient: false, taskIdentifier: identifier)
        }
      } else { _ = receiveResponse(response, identifier: identifier) }
    case .body(let data): receiveBody(data, identifier: identifier)
    case .complete(let error): completeRequest(error, identifier: identifier)
    }
  }

  private func handleAttemptFailure(
    _ error: NativePlayerError,
    transient: Bool,
    taskIdentifier: Int,
    retryAfter: String? = nil,
    expectedGeneration: UInt64? = nil
  ) {
    var retry: (attempt: Int, delay: Int64, offset: Int64,
                validator: YlNetworkResponseMetadata?)?
    var terminalError: NativePlayerError?
    var taskToCancel: URLSessionDataTask?

    stateLock.lock()
    guard !cancelled,
          expectedGeneration == nil || expectedGeneration == timerGeneration,
          currentTaskIdentifier == taskIdentifier else {
      stateLock.unlock()
      return
    }
    taskToCancel = activeTask
    if activeTask != nil { ignoredTaskIdentifiers.insert(taskIdentifier) }
    activeTask = nil
    managedTransport?.cancel(); managedTransport = nil; managedIdentifier = nil
    cancelTimersLocked()

    let canResume = (recipe.mode == .randomAccessVOD
      && (bytesThisAttempt == 0 || metadata?.supportsRandomAccess == true))
      || (recipe.managedIntent != nil && bytesThisAttempt == 0)
    let nextAttempt: Int?
    if transient && canResume {
      nextAttempt = recipe.managedIntent?.nextRetry(maximum: recipe.configuration.maxRetries)
        ?? (recipe.managedIntent == nil && retryCount < recipe.configuration.maxRetries ? retryCount + 1 : nil)
    } else { nextAttempt = nil }
    if let attempt = nextAttempt,
       let delay = managedPolicy.retryDelay(attempt: attempt, configuration: recipe.configuration, retryAfter: retryAfter) {
      retryCount = attempt
      retry = (attempt, delay, writeOffset, metadata)
    } else if transient && (recipe.mode == .randomAccessVOD || recipe.managedIntent != nil) {
      terminalError = NativePlayerError(
        category: "network", code: "network.retry_exhausted",
        message: "Network media retries were exhausted.", diagnostic: error.code)
    } else { terminalError = error }
    if let terminalError { recipe.managedIntent?.fail(terminalError) }
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
    managedPolicy.arm(after: delayMs) { [weak self] in
      guard let self else { return }
      self.startRequest(offset: offset, validator: validator,
        resetRetryCount: false, expectedGeneration: generation)
    }
    stateLock.unlock()
  }

  private func armTimerLocked(_ deadline: Deadline, milliseconds: Int64) {
    timerGeneration &+= 1
    let generation = timerGeneration
    managedPolicy.arm(after: milliseconds) { [weak self] in
      self?.deadlineFired(deadline, generation: generation)
    }
  }

  private func deadlineFired(_ deadline: Deadline, generation: UInt64) {
    let taskIdentifier: Int? = stateLock.withLock {
      guard !cancelled, timerGeneration == generation else { return nil }
      return currentTaskIdentifier
    }
    guard let taskIdentifier else { return }
    let error = NativePlayerError(
      category: "network",
      code: deadline == .connect ? "network.connect_timeout" : "network.read_timeout",
      message: deadline == .connect
        ? "The network connection timed out."
        : "The network media read timed out."
    )
    handleAttemptFailure(error, transient: true, taskIdentifier: taskIdentifier, expectedGeneration: generation)
  }

  private func cancelTimersLocked() {
    timerGeneration &+= 1
    managedPolicy.cancel()
  }

  private func cancelConnectAndArmRead(taskIdentifier: Int) {
    stateLock.withLock {
      guard currentTaskIdentifier == taskIdentifier, !cancelled else { return }
      armTimerLocked(.read, milliseconds: recipe.configuration.readTimeoutMs)
    }
  }

  private func pauseReadDeadline(taskIdentifier: Int) -> Bool {
    stateLock.withLock {
      guard currentTaskIdentifier == taskIdentifier,
            responseAccepted, !cancelled else { return false }
      // Delegate backpressure blocks further body delivery. Exclude the time
      // spent waiting for our consumer; resume when delivery can progress.
      cancelTimersLocked()
      return true
    }
  }

  private func resumeReadDeadline(
    taskIdentifier: Int,
    byteCount: Int
  ) -> Int64? {
    stateLock.withLock {
      guard currentTaskIdentifier == taskIdentifier,
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
      guard currentTaskIdentifier == taskIdentifier, !cancelled else {
        return false
      }
      metadata = received
      responseAccepted = true
      return true
    }
  }

  private func isActive(_ taskIdentifier: Int) -> Bool {
    stateLock.withLock {
      !cancelled && currentTaskIdentifier == taskIdentifier
    }
  }

  private static func transportError(_ error: Error) -> NativePlayerError {
    let value = error as NSError
    return NativePlayerError(
      category: "network",
      code: "network.http_status",
      message: "The network media request failed.",
      diagnostic: "transport.\(value.code)"
    )
  }


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

    completionHandler(receiveResponse(response, identifier: dataTask.taskIdentifier) ? .allow : .cancel)
  }

  private func receiveResponse(_ response: HTTPURLResponse, identifier: Int) -> Bool {
    if YlNetworkRequestPolicy.isRetryableStatus(response.statusCode) {
      let error = NativePlayerError(
        category: "network",
        code: "network.http_status",
        message: "The server returned a retryable HTTP status.",
        diagnostic: "HTTP \(response.statusCode)"
      )
      handleAttemptFailure(error, transient: true, taskIdentifier: identifier,
        retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
      return false
    }

    do {
      let received = try policy.validate(
        response: response,
        requestedOffset: stateLock.withLock { requestedOffset }
      )
      guard accept(received, taskIdentifier: identifier) else {
        return false
      }
      if received.isEOF {
        completeRequest(nil, identifier: identifier)
        return false
      } else {
        cancelConnectAndArmRead(taskIdentifier: identifier)
      }
      return true
    } catch let error as NativePlayerError {
      handleAttemptFailure(error, transient: false, taskIdentifier: identifier)
      return false
    } catch {
      handleAttemptFailure(
        Self.transportError(error),
        transient: false,
        taskIdentifier: identifier
      )
      return false
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    receiveBody(data, identifier: dataTask.taskIdentifier)
  }

  private func receiveBody(_ data: Data, identifier: Int) {
    guard !data.isEmpty,
          pauseReadDeadline(taskIdentifier: identifier) else { return }
    guard let target = stateLock.withLock({ () -> (Int64, UInt64)? in
      guard !cancelled, currentTaskIdentifier == identifier else { return nil }
      return (writeOffset, ring.writeGeneration)
    }) else { return }
    do {
      let callbackReservation = try identifier >= 0
        ? recipe.bufferScope?.require(category: .networkCache, bytes: data.count) : nil
      defer { withExtendedLifetime(callbackReservation) {} }
      try ring.write(data, at: target.0, generation: target.1)
      guard resumeReadDeadline(
        taskIdentifier: identifier,
        byteCount: data.count
      ) != nil else {
        handleAttemptFailure(
          NativePlayerError(
            category: "network",
            code: "network.range_invalid",
            message: "The network byte offset overflowed."
          ),
          transient: false,
          taskIdentifier: identifier
        )
        return
      }
    } catch YlByteSourceError.cancelled {
      return
    } catch let YlByteSourceError.failed(error) {
      handleAttemptFailure(error, transient: false, taskIdentifier: identifier)
    } catch {
      handleAttemptFailure(
        Self.transportError(error),
        transient: false,
        taskIdentifier: identifier
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
    completeRequest(error, identifier: task.taskIdentifier)
  }

  private func completeRequest(_ error: Error?, identifier: Int) {
    guard isActive(identifier) else { return }
    if let error {
      handleAttemptFailure(
        error as? NativePlayerError ?? Self.transportError(error),
        transient: YlManagedRequestPolicy.isTransient(error),
        taskIdentifier: identifier
      )
      return
    }
    stateLock.withLock {
      guard currentTaskIdentifier == identifier else { return }
      activeTask = nil
      managedTransport?.cancel(); managedTransport = nil; managedIdentifier = nil
      cancelTimersLocked()
      recipe.managedIntent?.completed()
      ring.finish()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard isActive(task.taskIdentifier) else { completionHandler(nil); return }
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
      let redirected = try policy.redirectRequest(from: sourceURL, response: response, to: destinationURL)
      let accepted = stateLock.withLock { () -> Bool in
        guard !cancelled, currentTaskIdentifier == task.taskIdentifier else { return false }
        cancelTimersLocked()
        armTimerLocked(.connect, milliseconds: recipe.configuration.connectTimeoutMs)
        return true
      }
      completionHandler(accepted ? redirected : nil)
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
