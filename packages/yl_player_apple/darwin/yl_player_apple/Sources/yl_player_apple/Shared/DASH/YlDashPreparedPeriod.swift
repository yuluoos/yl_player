import CoreMedia
import Foundation

/// Candidate preparation owns no public output. Selection is resolved against
/// the new Period before any accepted decoder, audio intent or catalog changes.
final class YlDashPreparedPeriod {
  let index: Int
  let window: YlDashProgramTimeline.Window
  let position: YlDashProgramTime
  let video: YlDashTrackCursor
  let audio: YlDashTrackCursor?
  let firstVideo: YlDashTrackCursor.Item
  let firstAudio: YlDashTrackCursor.Item?
  let selection: YlNativeVideoSelection
  let qualityFamily: String

  init(program: YlDashProgram, index: Int, position: YlDashProgramTime,
       constraints: YlAppleVideoConstraints, selection: YlNativeVideoSelection,
       explicitAudio: String?, preferredAudio: String?, qualityFamily: String?,
       resources: YlDashProgramResources, cancellation: YlOpenCancellationToken,
       scope: YlManagedBufferScope) throws {
    guard program.periods.indices.contains(index) else { throw YlDashProgramError.invalidPeriod }
    self.index = index; window = program.timeline.windows[index]
    self.position = max(position, window.start)
    let tracks = program.periods[index].tracks
    let candidates = tracks.filter {
      $0.kind == .video && $0.width <= Int64(constraints.maxWidth ?? Int.max)
        && $0.height <= Int64(constraints.maxHeight ?? Int.max)
        && $0.bandwidth <= Int64(constraints.maxBitrate ?? Int.max)
    }.sorted { $0.bandwidth == $1.bandwidth ? $0.id < $1.id : $0.bandwidth > $1.bandwidth }
    guard !candidates.isEmpty else { throw YlAppleVideoConstraints.unsupportedOutput }
    var resolved = selection
    let fixed = selection.fixedTrackId.flatMap { id in candidates.first { $0.id == id } }
    if selection.fixedTrackId != nil, fixed == nil { resolved = .init(reason: "trackUnavailable") }
    self.selection = resolved
    // The format's actual transfer/Dolby path is authoritative. Try other
    // declared candidates only when their configuration belongs to another
    // quality family; network/decoder errors do not silently change user intent.
    var chosen: (YlDashTrackCursor, YlDashTrackCursor.Item, String)?
    for track in fixed.map({ [$0] }) ?? candidates {
      let cursor = try YlDashTrackCursor(track: track, window: window, position: self.position,
        resources: resources, cancellation: cancellation, scope: scope)
      guard let first = try cursor.next(), let format = first.source.videoFormat,
            first.packet.keyframe else { throw Self.invalid() }
      let dimensions = CMVideoFormatDescriptionGetDimensions(format)
      guard dimensions.width == track.width, dimensions.height == track.height else { throw Self.invalid() }
      let family = Self.family(format)
      if let qualityFamily, family != qualityFamily { continue }
      chosen = (cursor, first, family); break
    }
    guard let chosen else { throw YlAppleVideoConstraints.unsupportedOutput }
    video = chosen.0; firstVideo = chosen.1; self.qualityFamily = chosen.2
    let audios = tracks.filter { $0.kind == .audio }
    let audioTrack: YlDashProgram.Track?
    if let explicitAudio {
      guard let match = audios.first(where: { $0.id == explicitAudio }) else {
        throw NativePlayerError(category: "track", code: "track.not_found", message: "The selected audio content is absent from this Period.")
      }
      audioTrack = match
    } else {
      audioTrack = preferredAudio.flatMap { id in audios.first { $0.id == id } }
        ?? audios.first(where: { $0.roles.contains("main") }) ?? audios.first
    }
    if let audioTrack {
      let cursor = try YlDashTrackCursor(track: audioTrack, window: window, position: self.position,
        resources: resources, cancellation: cancellation, scope: scope)
      guard let first = try cursor.next() else { throw Self.invalid() }
      audio = cursor; firstAudio = first
    } else { audio = nil; firstAudio = nil }
    try cancellation.throwIfCancelled()
  }
  private static func family(_ format: CMVideoFormatDescription) -> String {
    let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? "unspecified"
    let dolby = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC
    return dolby ? "dolby:" + transfer : YlHDRVideoPolicy.isHDR(format) ? "hdr:" + transfer : "sdr"
  }
  private static func invalid() -> NativePlayerError {
    NativePlayerError(category: "container", code: "container.dash_sample_invalid", message: "The DASH Representation does not match its independently decodable configuration.")
  }
}
