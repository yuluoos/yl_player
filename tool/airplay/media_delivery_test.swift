import Foundation
import yl_player_media_core
@testable import yl_player_media_delivery

/// Exercises the production manager without a player or a generated wire codec.
@main struct DeliveryQueueTests {
  final class WeakScope {
    weak var value: YlManagedBufferScope?
    init(_ value: YlManagedBufferScope) { self.value = value }
  }
  final class Starts {
    private let lock = NSLock()
    private var values = [String]()
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
  }
  static func spin(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(predicate(), "Timed out waiting for manager")
  }
  static func input(_ name: String, scopes: inout [WeakScope]) throws -> YlMediaDeliveryInput {
    let scope = try YlManagedBufferLedger().makeScope(maxBytes: nil)
    scopes.append(WeakScope(scope))
    return YlMediaDeliveryInput(recipe: .rtmp(request: YlRtmpRequestRecipe(
      address: try YlRtmpAddress("rtmp://example.com/live/\(name)"),
      recovery: YlRtmpRecoveryBudget(), bufferScope: scope)), isLive: true)
  }
  static func main() throws {
    let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
    let starts = Starts()
    var cleanups = 0
    var results = [String: Result<URL, Error>]()
    var callbacks = [String: Int]()
    var scopes = [WeakScope]()
    let manager = YlMediaDeliveryManager(prepare: { input, token in
      guard case .rtmp(let request) = input.recipe else { fatalError("Missing RTMP recipe") }
      let name = request.address.playpath
      starts.append(name)
      if name == "blocked" {
        entered.signal()
        // Model an in-progress native operation that cannot finish on cancellation.
        precondition(gate.wait(timeout: .now() + 10) == .success)
        try token.throwIfCancelled()
      }
      return YlDeliveredMedia(url: URL(string: "http://127.0.0.1:1234/\(name)/index.m3u8")!,
        cleanup: { cleanups += 1 })
    }, currentAddress: { "127.0.0.1" })
    func prepare(_ id: String) throws {
      manager.prepare(id: id, input: try input(id, scopes: &scopes)) {
        callbacks[id, default: 0] += 1
        results[id] = $0
      }
    }
    try prepare("accepted")
    spin { results["accepted"] != nil }
    _ = try results["accepted"]!.get()
    try prepare("blocked")
    precondition(entered.wait(timeout: .now() + 5) == .success)
    for index in 0..<1000 { try prepare("replacement-\(index)") }
    precondition(starts.all == ["accepted", "blocked"], "More than one producer ran")
    precondition(scopes.filter { $0.value != nil }.count == 2,
      "Superseded requests retained inputs in an unbounded preparation queue")
    precondition(results.count == 1001 && results["replacement-999"] == nil,
      "Every superseded request must settle immediately; only latest may remain pending")
    precondition(cleanups == 0, "Replacement burst released accepted media too early")
    gate.signal()
    spin { results["replacement-999"] != nil }
    _ = try results["replacement-999"]!.get()
    precondition(starts.all == ["accepted", "blocked", "replacement-999"],
      "Superseded candidates reached the producer")
    precondition(cleanups == 1, "Latest success must replace the accepted media once")
    precondition(callbacks.values.allSatisfy { $0 == 1 }, "A prepare callback fired more than once")
    for (id, result) in results where id != "accepted" && id != "replacement-999" {
      guard case .failure(let error) = result else { fatalError("Superseded input succeeded") }
      precondition((error as? NativePlayerError)?.code == "load.cancelled")
    }
    manager.close(); manager.close()
    precondition(cleanups == 2, "Close must release accepted media exactly once")
    print("PASS 1000 replacements retain one running and one pending input, cancel once, and retire leases once")
  }
}
