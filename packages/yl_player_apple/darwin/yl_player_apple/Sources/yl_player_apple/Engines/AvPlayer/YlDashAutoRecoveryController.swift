import yl_player_media_core
import Foundation

/// Main-queue owner of a bounded, cancellable same-source recovery operation.
/// Cancelling preparation never refunds a reservation or mutates the active item.
final class YlDashAutoRecoveryController {
  typealias Sample = YlDashAutoRecoveryPolicy.Sample
  typealias Scheduler = (Double, @escaping () -> Void) -> Void
  private let clock: () -> Double
  private let schedule: Scheduler
  private let operation = YlOpenCoordinator(label: "dev.ylplayer.dash.automatic-recovery")
  private var sourceIdentity: YlAppleSessionIdentity?
  private var activeTicket: YlDashAutoRecoveryPolicy.Ticket?
  var onEvent: (([String: Any]) -> Void)?
  var onDecision: (([String: Any]) -> Void)?
  private(set) var policy = YlDashAutoRecoveryPolicy()
  private(set) var events: [[String: Any]] = []

  init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
       schedule: @escaping Scheduler = { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) }) {
    self.clock = clock; self.schedule = schedule
  }

  func useSource(_ identity: YlAppleSessionIdentity) {
    if sourceIdentity != identity { resetForSource(); sourceIdentity = identity }
  }

  func invalidate() {
    policy.invalidateIntent()
    operation.cancelCurrent()
  }

  func resetForSource() {
    invalidate()
    policy = YlDashAutoRecoveryPolicy(); events = []
  }

  func tick(_ sample: Sample?, prepare: @escaping YlOpenCoordinator.Preparation,
            currentSample: @escaping () -> Sample?, commit: @escaping (YlPreparedOpen) throws -> [String: Any]) {
    guard let sample else { invalidate(); return }
    let ticket = policy.observe(sample)
    onDecision?(policy.decision)
    if let activeTicket, !policy.authorizes(activeTicket, sample) { invalidate() }
    guard let ticket else { return }
    activeTicket = ticket
    let started = clock()
    let deadline = started + 2
    var event: [String: Any] = ["attempt": ticket.attempt, "due": ticket.due,
      "elapsed": started, "positionBefore": sample.position, "generation": ticket.generation,
      "ticketIntentRevision": ticket.intentRevision, "ticketCredentialRevision": ticket.credentialRevision,
      "preparationDeadline": deadline]
    operation.begin(prepare: prepare, commit: { [weak self] candidate in
      guard let self, self.activeTicket?.id == ticket.id, self.clock() <= deadline,
            let current = currentSample(), self.policy.authorizes(ticket, current) else {
        throw YlOpenCancellationToken.cancellationError()
      }
      let details = try commit(candidate)
      for key in ["itemChanged", "credentialCommitAccepted"] { event[key] = details[key] }
    }, completion: { [weak self] result in
      guard let self, self.activeTicket?.id == ticket.id else { return }
      self.activeTicket = nil
      let completedAt = self.clock()
      event["elapsedAfter"] = completedAt
      switch result {
      case .success:
        self.policy.finish(ticket, installedAt: completedAt)
        event["outcome"] = "installed"
      case .failure(let error):
        self.policy.finish(ticket)
        event["outcome"] = error.code == YlOpenCancellationToken.cancellationError().code ? "cancelled" : "preparationFailed"
        event["failureCode"] = error.code
      }
      self.events.append(event)
      self.onEvent?(event)
    })
    schedule(2) { [weak self] in
      guard let self, self.activeTicket?.id == ticket.id else { return }
      self.invalidate()
    }
  }
}
