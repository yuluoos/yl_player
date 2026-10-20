import yl_player_media_core
import CoreMedia
import Foundation

/// Serial elementary-stream cursor. Retains one initialization and one fragment;
/// packets retain only the demux owner from which they came. A seek creates a new
/// cursor so delayed results can never mutate an accepted cursor's position.
final class YlDashTrackCursor {
  typealias Time = YlDashProgramTime
  struct Item {
    let source: YlDashSampleSource
    let packet: YlDashSampleSource.Packet
    let pts: Time
    let dts: Time?
  }
  let track: YlDashProgram.Track
  let window: YlDashProgramTimeline.Window
  let presentationStart: Time
  private let periodStart: Time
  private let resources: YlDashProgramResources
  private let cancellation: YlOpenCancellationToken
  private let scope: YlManagedBufferScope
  private let initialization: YlDashProgramResources.Payload
  private let segmentLimit: Int
  private var segment: Int
  private var source: YlDashSampleSource?
  private var ended = false

  init(track: YlDashProgram.Track, window: YlDashProgramTimeline.Window, position: Time,
       resources: YlDashProgramResources, cancellation: YlOpenCancellationToken,
       scope: YlManagedBufferScope) throws {
    guard let initialization = track.initialization, track.kind != .text else { throw Self.unsupported() }
    self.track = track; self.window = window; self.periodStart = window.start
    self.resources = resources; self.cancellation = cancellation; self.scope = scope
    presentationStart = max(position, window.start)
    segmentLimit = min(8 * 1024 * 1024, max(1, scope.ledger.snapshot.maxBytes / 8))
    self.initialization = try resources.read(initialization, maximumBytes: 1024 * 1024, cancellation: cancellation)
    let sourcePosition = try presentationStart.subtracting(window.start).adding(track.offset)
    let selected = track.segments.lastIndex { $0.start <= sourcePosition } ?? 0
    // One preceding audio fragment gives the converter real codec preroll after
    // a seek; output clipping is based on exact sample time, not segment labels.
    segment = track.kind == .audio ? max(0, selected - 1) : selected
  }
  func next() throws -> Item? {
    while !ended {
      try cancellation.throwIfCancelled()
      if source == nil {
        guard segment < track.segments.count else { ended = true; return nil }
        let descriptor = track.segments[segment]
        let mapped = try descriptor.start.subtracting(track.offset).adding(periodStart)
        if mapped >= window.end { ended = true; return nil }
        let payload = try resources.read(descriptor.resource, maximumBytes: segmentLimit, cancellation: cancellation)
        source = try YlDashSampleSource(initialization: initialization, fragment: payload,
          kind: track.kind, cancellation: cancellation, scope: scope)
      }
      if let source, let packet = try source.next() {
        let pts = try packet.pts.subtracting(track.offset).adding(periodStart)
        let dts = try packet.dts.map { try $0.subtracting(track.offset).adding(periodStart) }
        // Decode order may differ from presentation order: a late PTS cannot
        // terminate this fragment before earlier B frames have been decoded.
        return Item(source: source, packet: packet, pts: pts, dts: dts)
      }
      source = nil; segment += 1
    }
    return nil
  }
  private static func unsupported() -> NativePlayerError {
    NativePlayerError(category: "container", code: "container.dash_sample_invalid",
      message: "The DASH track does not provide supported initialization data.")
  }
}
