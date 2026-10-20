import yl_player_media_core
import Foundation

/// Load-owned preparation; the decoder/output transaction is created at commit.
/// Discard cancels only this candidate's resources, never an accepted session.
final class YlPreparedDashProgram {
  let program: YlDashProgram
  let resources: YlDashProgramResources
  let scope: YlManagedBufferScope
  let cancellation: YlOpenCancellationToken
  private let ownershipLock = NSLock()
  private var initial: YlDashPreparedPeriod?
  let constraints: YlAppleVideoConstraints
  let decoderPolicy: YlDecoderPolicy
  let softwareServices: YlSoftwareDecodeServices
  let autoplay: Bool
  let position: YlDashProgramTime
  private var consumed = false

  init(program: YlDashProgram, resources: YlDashProgramResources, scope: YlManagedBufferScope,
       cancellation: YlOpenCancellationToken, constraints: YlAppleVideoConstraints = .unconstrained,
       decoderPolicy: YlDecoderPolicy = .systemDefault, autoplay: Bool = false, startPositionMs: Int64 = 0,
       softwareServices: YlSoftwareDecodeServices = .init()) throws {
    self.softwareServices = softwareServices
    self.program = program; self.resources = resources; self.scope = scope
    self.cancellation = cancellation; self.constraints = constraints
    self.decoderPolicy = decoderPolicy; self.autoplay = autoplay
    position = min(try YlDashProgramTime(max(0, startPositionMs), 1000), program.timeline.duration)
    if let index = program.timeline.locate(time: position) ?? program.timeline.windows.firstIndex(where: { $0.start > position }) {
      initial = try YlDashPreparedPeriod(program: program, index: index, position: position,
        constraints: constraints, selection: .init(), explicitAudio: nil, preferredAudio: nil,
        qualityFamily: nil, resources: resources, cancellation: cancellation, scope: scope)
    } else { initial = nil }
  }
  convenience init(source: YlAppleSourceDescriptor, configuration: PlayerConfiguration,
                   cancellation: YlOpenCancellationToken, constraints: YlAppleVideoConstraints) throws {
    guard let url = source.url, !source.isLive, source.kind == .network,
          source.loadOptions?.bufferStrategy != .bounded else {
      throw NativePlayerError(category: "unsupported", code: "policy.unsupported",
        message: "This DASH programme route requires static network media and automatic buffering.")
    }
    let scope = try source.bufferScope ?? YlManagedBufferLedger(maxBytes: 128 * 1024 * 1024).makeScope(maxBytes: nil)
    let resources = YlDashProgramResources(source: url, headers: source.headers,
      credentials: source.credentials, credentialsAllowed: source.credentialContext.maySendCredentials,
      rootIntent: source.managedRequestIntent, configuration: source.networkConfiguration.map(YlNetworkConfiguration.init(options:)) ?? configuration.network, scope: scope)
    let program = try YlDashProgramLoader.load(url: url, resources: resources, cancellation: cancellation)
    try self.init(program: program, resources: resources, scope: scope, cancellation: cancellation,
      constraints: constraints, decoderPolicy: source.loadOptions?.decoderPolicy ?? .systemDefault,
      autoplay: source.loadOptions?.autoplay ?? false, startPositionMs: source.loadOptions?.startPositionMs ?? 0)
  }
  /// Transfers the initial cursors into the accepted backend exactly once.
  func takeInitial() throws -> YlDashPreparedPeriod? {
    ownershipLock.lock(); defer { ownershipLock.unlock() }
    guard !consumed else { throw YlOpenCancellationToken.cancellationError() }
    consumed = true; let value = initial; initial = nil; return value
  }
  func discard() {
    cancellation.cancel()
    ownershipLock.lock(); initial = nil; ownershipLock.unlock()
  }
}
