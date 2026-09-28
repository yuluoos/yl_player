import AVFoundation
import Foundation

/// One driver and one fresh recipient per candidate. Only streaming licenses;
/// no persistence, advisory keys, vendor URL inference or automatic POST retries.
final class YlFairPlayDriver: NSObject, YlFairPlayDriving, AVContentKeySessionDelegate {
  private var session: AVContentKeySession?
  private var asset: AVURLAsset?
  private var events: YlFairPlayDriverEvents?
  private var requests = [ObjectIdentifier: Request]()
  private var closed = false

  func start(asset: AVURLAsset, events: YlFairPlayDriverEvents) throws {
    precondition(Thread.isMainThread)
    guard !closed, session == nil else { throw YlFairPlayFailure.error("drm.session_failed") }
    let session = AVContentKeySession(keySystem: .fairPlayStreaming)
    self.session = session; self.asset = asset; self.events = events
    session.setDelegate(self, queue: .main)
    // Caller must not load the asset before this registration (SDK precondition).
    session.addContentKeyRecipient(asset)
  }
  func close() {
    precondition(Thread.isMainThread)
    guard !closed else { return }
    closed = true
    let old = session; session = nil; events = nil
    old?.setDelegate(nil, queue: nil)
    if let asset { old?.removeContentKeyRecipient(asset) }
    self.asset = nil
    // Request objects must never be used once the owning session is expired.
    requests.values.forEach { $0.invalidate() }; requests.removeAll()
    old?.expire()
  }
  func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
    provided(session, keyRequest)
  }
  func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
    provided(session, keyRequest)
  }
  private func provided(_ session: AVContentKeySession, _ key: AVContentKeyRequest) {
    guard !closed, session === self.session else { return }
    let id = ObjectIdentifier(key)
    if let request = requests[id] { events?.provided(request); return }
    let request = Request(key)
    // The owner enforces the total bound; do not retain the rejected 4097th key.
    if requests.count < 4096 { requests[id] = request }
    events?.provided(request)
  }
  func contentKeySession(_ session: AVContentKeySession, contentKeyRequestDidSucceed keyRequest: AVContentKeyRequest) {
    guard session === self.session, let request = requests[ObjectIdentifier(keyRequest)] else { return }
    events?.succeeded(request)
  }
  func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError err: Error) {
    guard session === self.session, let request = requests[ObjectIdentifier(keyRequest)] else { return }
    // Arbitrary AVError/underlying provider strings never enter public diagnostics.
    events?.failed(request, .failed)
  }
  func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest,
                         reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
    guard session === self.session, let request = requests[ObjectIdentifier(keyRequest)] else { return false }
    // Only this explicit system reason means expired, never an HTTP status or
    // an expired-session report (which also records intentional close).
    events?.failed(request, retryReason == .receivedResponseWithExpiredLease ? .expired : .failed)
    return false
  }
  private final class Request: YlFairPlayRequest {
    private var request: AVContentKeyRequest?
    init(_ request: AVContentKeyRequest) { self.request = request }
    func makeChallenge(certificate: Data, contentId: Data, completion: @escaping (Result<Data, Error>) -> Void) {
      guard let request else { completion(.failure(YlFairPlayFailure.error("load.cancelled"))); return }
      request.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: contentId, options: nil) { data, error in
        if let data, error == nil { completion(.success(data)) }
        else { completion(.failure(YlFairPlayFailure.error("drm.session_failed"))) }
      }
    }
    func respond(_ data: Data) {
      request?.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: data))
    }
    func reject(_ error: NativePlayerError) {
      request?.processContentKeyResponseError(NSError(domain: "dev.ylplayer.drm", code: 1,
        userInfo: [NSLocalizedDescriptionKey: error.message]))
    }
    func invalidate() { request = nil }
  }
}
