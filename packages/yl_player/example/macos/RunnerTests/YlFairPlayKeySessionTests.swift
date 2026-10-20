@testable import yl_player_media_core
@testable import yl_player_apple
import AVFoundation
import XCTest

final class YlFairPlayKeySessionTests: XCTestCase {
  func testResponseIsNotUsableUntilMatchingSystemSuccessAndRenewalWithdrawsReadiness() throws {
    let f = try Fixture()
    let request = Request()
    f.driver.events!.provided(request)
    XCTAssertFalse(f.session.isUsable)
    request.challenge?(.success(Data([7])))
    XCTAssertEqual(f.sent.count, 1)
    f.replies[0](.success(Data([8])))
    XCTAssertEqual(request.responses, [Data([8])])
    XCTAssertFalse(f.session.isUsable)
    f.driver.events!.succeeded(request)
    XCTAssertTrue(f.session.isUsable)
    let renewal = Request()
    f.driver.events!.provided(renewal)
    XCTAssertFalse(f.session.isUsable)
    renewal.challenge?(.success(Data([9])))
    f.replies[1](.success(Data([10])))
    f.driver.events!.succeeded(renewal)
    XCTAssertTrue(f.session.isUsable)
    f.session.close()
  }

  func testSuspendAndNewRecipientFenceLateChallengeResponseAndSystemCallbacks() throws {
    let f = try Fixture()
    let old = Request()
    f.driver.events!.provided(old)
    old.challenge?(.success(Data([7])))
    let oldEvents = f.driver.events!
    f.session.suspend()
    XCTAssertEqual(f.driver.closes, 1)
    XCTAssertEqual(f.cancelled, 1)
    let next = Driver()
    f.next = next
    try f.session.start(asset: AVURLAsset(url: URL(string: "https://media.test/new.m3u8")!))
    f.replies[0](.success(Data([8])))
    oldEvents.succeeded(old)
    oldEvents.provided(Request())
    XCTAssertTrue(old.responses.isEmpty)
    XCTAssertFalse(f.session.isUsable)
    XCTAssertEqual(f.sent.count, 1)
    let current = Request()
    next.events!.provided(current)
    current.challenge?(.success(Data([9])))
    XCTAssertNotEqual(f.sent[0].epoch, f.sent[1].epoch)
    f.session.close()
  }

  func testDuplicateRequestsDoNotPostTwiceAndLimitFailsClosed() throws {
    let f = try Fixture()
    let request = Request()
    f.driver.events!.provided(request)
    f.driver.events!.provided(request)
    request.challenge?(.success(Data([7])))
    request.challenge?(.success(Data([7])))
    XCTAssertEqual(f.sent.count, 1)
    for _ in 0..<4 { f.driver.events?.provided(Request()) }
    XCTAssertEqual(f.failures.last?.code, "resource.exhausted")
    XCTAssertEqual(f.driver.closes, 1)
    XCTAssertFalse(f.session.isUsable)
  }

  func testDeadlineIncludesChallengeAndSystemConfirmation() throws {
    for stage in 0..<3 {
      let f = try Fixture()
      let request = Request()
      f.driver.events!.provided(request)
      if stage > 0 { request.challenge?(.success(Data([7]))) }
      if stage > 1 { f.replies[0](.success(Data([8]))) }
      f.timers[0]()
      XCTAssertEqual(f.failures.last?.code, "drm.license_timeout")
      XCTAssertEqual(f.driver.closes, 1)
      XCTAssertFalse(f.session.isUsable)
    }
  }

  func testTransportFailuresRemainTypedAndExpiredNeedsExplicitSystemEvidence() throws {
    for code in ["drm.license_denied", "drm.license_redirect_rejected", "drm.license_timeout"] {
      let f = try Fixture()
      let request = Request()
      f.driver.events!.provided(request)
      request.challenge?(.success(Data([7])))
      f.replies[0](.failure(.init(category: "network", code: code, message: "SECRET")))
      XCTAssertEqual(f.failures.last?.code, code)
      XCTAssertFalse(f.failures.last!.message.contains("SECRET"))
    }
    let f = try Fixture()
    let request = Request()
    f.driver.events!.provided(request)
    f.driver.events!.failed(request, .expired)
    XCTAssertEqual(f.failures.last?.code, "drm.license_expired")
  }

  func testUnsolicitedSuccessAndOversizedPayloadCannotAuthorizeKeys() throws {
    let f = try Fixture()
    f.driver.events!.succeeded(Request())
    XCTAssertFalse(f.session.isUsable)
    let request = Request()
    f.driver.events!.provided(request)
    f.driver.events!.succeeded(request)
    XCTAssertFalse(f.session.isUsable)
    request.challenge?(.success(Data(repeating: 1, count: 1024 * 1024 + 1)))
    XCTAssertEqual(f.failures.last?.code, "drm.payload_too_large")
    XCTAssertTrue(f.sent.isEmpty)
  }

  func testSynchronousCallbacksCannotLoseCancellationOrReuseClosedSession() throws {
    let driver = Driver()
    let request = Request()
    var cancellations = 0
    var failures = [NativePlayerError]()
    let session = try YlFairPlayKeySession(certificate: Data([1]), contentId: Data([2]), timeoutMs: 1000,
      makeDriver: { driver }, exchange: { _, _, completion in
        completion(.failure(YlFairPlayFailure.error("drm.license_denied")))
        return { cancellations += 1 }
      }, onChange: {}, onFailure: { failures.append($0) })
    try session.start(asset: AVURLAsset(url: URL(string: "https://media.test/a.m3u8")!))
    driver.events!.provided(request)
    request.challenge?(.success(Data([7])))
    XCTAssertEqual(failures.count, 1)
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(driver.closes, 1)
    session.close(); session.close()
    XCTAssertThrowsError(try session.start(asset: AVURLAsset(url: URL(string: "https://media.test/b.m3u8")!)))
  }

  func testExpiredRecipientCannotBeReusedAfterSuspension() throws {
    let driver = Driver()
    let session = try YlFairPlayKeySession(certificate: Data([1]), contentId: Data([2]), timeoutMs: 1000,
      makeDriver: { driver }, exchange: { _, _, _ in {} }, onChange: {}, onFailure: { _ in })
    let asset = AVURLAsset(url: URL(string: "https://media.test/a.m3u8")!)
    try session.start(asset: asset)
    session.suspend()
    XCTAssertThrowsError(try session.start(asset: asset))
    session.close()
  }

  func testOwnerDeallocationCancelsRequestsBeforeClosingDriver() throws {
    let driver = Driver()
    let request = Request()
    var cancels = 0
    var session: YlFairPlayKeySession? = try YlFairPlayKeySession(certificate: Data([1]), contentId: Data([2]), timeoutMs: 1000,
      makeDriver: { driver }, exchange: { _, _, _ in { cancels += 1 } }, onChange: {}, onFailure: { _ in })
    try session!.start(asset: AVURLAsset(url: URL(string: "https://media.test/a.m3u8")!))
    driver.events!.provided(request)
    request.challenge?(.success(Data([7])))
    session = nil
    XCTAssertEqual(cancels, 1)
    XCTAssertEqual(driver.closes, 1)
    XCTAssertEqual(request.rejections, ["load.cancelled"])
  }

  func testConcurrentKeysNeedAllConfirmationsAndCancelledDeadlinesStayStale() throws {
    let f = try Fixture()
    let a = Request(), b = Request()
    f.driver.events!.provided(a); f.driver.events!.provided(b)
    a.challenge?(.success(Data([7]))); b.challenge?(.success(Data([9])))
    f.replies[0](.success(Data([8]))); f.replies[1](.success(Data([10])))
    f.driver.events!.succeeded(a)
    XCTAssertFalse(f.session.isUsable)
    f.driver.events!.succeeded(b)
    XCTAssertTrue(f.session.isUsable)
    f.timers.forEach { $0() }
    XCTAssertTrue(f.failures.isEmpty)
    f.driver.events!.failed(b, .protection)
    XCTAssertFalse(f.session.isUsable)
    XCTAssertEqual(f.failures.last?.code, "drm.protection_insufficient")
  }

  func testInvalidLicenseResponseNeverReachesSystemAndTransportCannotInventExpiry() throws {
    for bytes in [Data(), Data(repeating: 1, count: 4 * 1024 * 1024 + 1)] {
      let f = try Fixture(), request = Request()
      f.driver.events!.provided(request); request.challenge?(.success(Data([7])))
      f.replies[0](.success(bytes))
      XCTAssertTrue(request.responses.isEmpty)
      XCTAssertEqual(f.failures.last?.code, bytes.isEmpty ? "drm.license_response_invalid" : "drm.payload_too_large")
    }
    let f = try Fixture(), request = Request()
    f.driver.events!.provided(request); request.challenge?(.success(Data([7])))
    f.replies[0](.failure(.init(category: "platform", code: "drm.license_expired", message: "SECRET")))
    XCTAssertEqual(f.failures.last?.code, "drm.license_failed")
  }

  func testCancelledExchangeKeepsItsPublicDiagnosticMeaning() throws {
    let f = try Fixture(), request = Request()
    f.driver.events!.provided(request); request.challenge?(.success(Data([7])))
    f.replies[0](.failure(.init(category: "cancelled", code: "load.cancelled", message: "SECRET")))
    let wire = YlAppleSafeDiagnostics.failure(try XCTUnwrap(f.failures.last), scope: .session)
    XCTAssertEqual(wire.code, "load.cancelled")
    XCTAssertEqual(wire.category, .cancelled)
    XCTAssertEqual(wire.message, "The load was cancelled.")
  }

  func testReadinessIsRevokedBeforeDriverCleanup() throws {
    let f = try Fixture(), request = Request()
    f.driver.events!.provided(request); request.challenge?(.success(Data([7])))
    f.replies[0](.success(Data([8]))); f.driver.events!.succeeded(request)
    XCTAssertTrue(f.session.isUsable)
    var observed: Bool?
    f.driver.onClose = { observed = f.session.isUsable }
    f.session.suspend()
    XCTAssertEqual(observed, false)
    f.session.close()
  }

  func testConfigurationLimitsAndSafeDiagnostics() throws {
    XCTAssertThrowsError(try YlFairPlayKeySession(certificate: Data(), contentId: Data([2]), timeoutMs: 10,
      exchange: { _, _, _ in {} }, onChange: {}, onFailure: { _ in }))
    for code in YlFairPlayFailure.codes {
      let error = YlFairPlayFailure.error(code)
      let wire = YlAppleSafeDiagnostics.failure(error, scope: .session)
      XCTAssertEqual(wire.code, code)
      XCTAssertNotEqual(wire.message, "Playback failed for an unknown reason.")
    }
  }
}

private final class Request: YlFairPlayRequest {
  var challenge: ((Result<Data, Error>) -> Void)?
  var responses = [Data]()
  var rejections = [String]()
  func makeChallenge(certificate: Data, contentId: Data, completion: @escaping (Result<Data, Error>) -> Void) { challenge = completion }
  func respond(_ data: Data) { responses.append(data) }
  func reject(_ error: NativePlayerError) { rejections.append(error.code) }
}
private final class Driver: YlFairPlayDriving {
  var events: YlFairPlayDriverEvents?
  var closes = 0
  var onClose: (() -> Void)?
  func start(asset: AVURLAsset, events: YlFairPlayDriverEvents) throws { self.events = events }
  func close() { closes += 1; events = nil; onClose?() }
}
private final class Fixture {
  let driver = Driver()
  var next: Driver?
  var session: YlFairPlayKeySession!
  var sent = [YlFairPlayExchangeIdentity]()
  var replies = [(Result<Data, NativePlayerError>) -> Void]()
  var timers = [() -> Void]()
  var failures = [NativePlayerError]()
  var cancelled = 0
  init() throws {
    session = try YlFairPlayKeySession(certificate: Data([1]), contentId: Data([2]), timeoutMs: 1000,
      makeDriver: { [unowned self] in next ?? driver },
      schedule: { [unowned self] _, action in timers.append(action); return {} },
      exchange: { [unowned self] id, _, completion in
        sent.append(id); replies.append(completion)
        return { [weak self] in self?.cancelled += 1 }
      }, onChange: {}, onFailure: { [unowned self] in failures.append($0) })
    try session.start(asset: AVURLAsset(url: URL(string: "https://media.test/a.m3u8")!))
  }
}
