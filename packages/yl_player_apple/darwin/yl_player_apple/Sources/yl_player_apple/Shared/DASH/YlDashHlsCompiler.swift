import Foundation

struct YlDashHlsPresentation {
  let rootURL: URL
  let manifests: [URL: Data]
  let strippedResources: Set<String>
  let durationUs: Int64
  let videoCatalog: YlDashVideoCatalog
  let audioCatalog: [YlNativeTrack]
}

/// Declared available qualities, not AVPlayer's current adaptive selection.
struct YlDashVideoCatalog {
  private struct Period {
    let startUs: Int64
    let endUs: Int64
    let tracks: [YlNativeTrack]
  }
  private let periods: [Period]

  init(periods: [YlDashPeriod]) {
    self.periods = periods.map { period in
      var identities = Set<String>()
      let tracks = period.videos.sorted {
        ($0.width, $0.height, $0.bandwidth) < ($1.width, $1.height, $1.bandwidth)
      }.compactMap { video -> YlNativeTrack? in
        let id = "dash-video-w\(video.width)-h\(video.height)-b\(video.bandwidth)"
        // Legacy admission can include duplicate display qualities; keep media
        // paths untouched and deduplicate only this bounded public projection.
        guard identities.insert(id).inserted else { return nil }
        return YlNativeTrack(id: id, kind: .video, codec: video.codec,
          bitrate: Int(video.bandwidth), width: Int(video.width), height: Int(video.height))
      }
      return Period(startUs: period.startUs, endUs: period.endUs, tracks: tracks)
    }
  }

  func tracks(at positionUs: Int64) -> [YlNativeTrack] {
    let position = max(0, positionUs)
    return periods.first { position >= $0.startUs && position < $0.endUs }?.tracks
      ?? periods.last?.tracks ?? []
  }
}

enum YlDashHlsCompiler {
  private enum ProjectionError: Error { case noEligibleVideo, invalidSelection }
  static func compile(data: Data, finalManifestURL: URL, sourceURL: URL,
    credentialsStripped: Bool, indexes: [YlDashIndexRequest: YlDashResolvedIndex] = [:], videoConstraints: YlAppleVideoConstraints = .unconstrained, fixedTrackId: String? = nil, manifestURL: (String) throws -> URL,
    mediaURL: (URL, Bool) throws -> URL) throws -> YlDashHlsPresentation {
    do {
      let document = YlDashDocument(source: sourceURL, indexes: indexes)
      let (originalPeriods, duration) = try document.parse(data, final: finalManifestURL,
        credentialsStripped: credentialsStripped)
      // Fixed policy uses the strict admitted semantic family. IDs and XML order
      // are immaterial; duplicate display identities are rejected before pruning.
      if fixedTrackId != nil { _ = try YlDashVideoPaths.plan(originalPeriods, strictFamily: true) }
      let periods: [YlDashPeriod]
      if videoConstraints != .unconstrained {
        // Validate the complete original family before pruning can hide a track.
        _ = try YlDashVideoPaths.plan(originalPeriods, strictFamily: true)
        periods = try originalPeriods.map { period in
          let videos = period.videos.filter { track in
            (videoConstraints.maxWidth.map { track.width <= Int64($0) } ?? true)
              && (videoConstraints.maxHeight.map { track.height <= Int64($0) } ?? true)
              && (videoConstraints.maxBitrate.map { track.bandwidth <= Int64($0) } ?? true)
          }
          guard !videos.isEmpty else { throw ProjectionError.noEligibleVideo }
          return YlDashPeriod(startUs: period.startUs, endUs: period.endUs, videos: videos, audios: period.audios)
        }
      } else { periods = originalPeriods }
      var mediaPeriods = periods
      if let fixedTrackId {
        func identity(_ track: YlDashTrack) -> String {
          "dash-video-w\(track.width)-h\(track.height)-b\(track.bandwidth)"
        }
        guard originalPeriods.contains(where: { $0.videos.contains { identity($0) == fixedTrackId } }) else {
          throw ProjectionError.invalidSelection
        }
        mediaPeriods = try zip(originalPeriods, periods).map { original, allowed in
          let originals = original.videos.filter { identity($0) == fixedTrackId }
          let matches = allowed.videos.filter { identity($0) == fixedTrackId }
          guard originals.isEmpty || matches.count == 1 else { throw ProjectionError.noEligibleVideo }
          return YlDashPeriod(startUs: allowed.startUs, endUs: allowed.endUs,
            videos: matches.isEmpty ? allowed.videos : matches, audios: allowed.audios)
        }
      }
      let videoPaths = try YlDashVideoPaths.plan(mediaPeriods)
      let videoNames = videoPaths.count == 1 ? ["video"]
        : videoPaths.indices.map { "video-\($0)" }
      let audios = periods[0].audios
      let audioNames = audios.count == 1 ? ["audio"] : audios.indices.map { "audio-\($0)" }
      let audioPaths = try audios.map { audio in
        try periods.map { period -> YlDashTrack in
          guard let match = period.audios.first(where: { $0.audioIdentity == audio.audioIdentity }) else { throw YlDashBounds.unsupported }
          return match
        }
      }
      let names = ["master"] + videoNames + audioNames
      var identities: [String: URL] = [:]
      for name in names {
        let url = try YlDashBounds.url(manifestURL(name).absoluteString)
        guard !identities.values.contains(url) else { throw YlDashBounds.unsupported }
        identities[name] = url
      }
      var registry: [URL: Data] = [:]
      var registryBytes = 0
      func store(_ name: String, _ text: String) throws {
        let bytes = text.utf8.count
        guard bytes <= YlDashBounds.maxDocument,
              bytes <= 4 * 1024 * 1024 - registryBytes else { throw YlDashBounds.unsupported }
        registryBytes += bytes; registry[identities[name]!] = Data(text.utf8)
      }
      func append(_ line: String, to text: inout String) throws {
        guard line.utf8.count <= min(YlDashBounds.maxDocument, 4 * 1024 * 1024 - registryBytes) - text.utf8.count else { throw YlDashBounds.unsupported }
        text += line
      }
      func escapedMedia(_ resource: YlDashResource) throws -> String {
        let url = try mediaURL(resource.url, document.stripped.contains(resource.url.absoluteString))
        let safe = try YlDashBounds.url(url.absoluteString).absoluteString
        guard !safe.contains("\""), !safe.contains("\\") else { throw YlDashBounds.unsupported }
        return safe
      }
      for name in names where name != "master" {
        let videoIndex = videoNames.firstIndex(of: name)
        let tracks = videoIndex.map { videoPaths[$0] } ?? audioPaths[audioNames.firstIndex(of: name)!]
        var target: Int64 = 1
        for track in tracks {
          for segment in track.segments {
            target = max(target, segment.ticks / segment.scale + (segment.ticks % segment.scale == 0 ? 0 : 1))
          }
        }
        var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for (index, track) in tracks.enumerated() {
          if index > 0 { try append("#EXT-X-DISCONTINUITY\n", to: &playlist) }
          let initial = try escapedMedia(track.initialization)
          let range = track.initialization.range.map { ",BYTERANGE=\"\($0)\"" } ?? ""
          try append("#EXT-X-MAP:URI=\"\(initial)\"\(range)\n", to: &playlist)
          for segment in track.segments {
            let seconds = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), Double(segment.ticks) / Double(segment.scale))
            try append("#EXTINF:\(seconds),\n", to: &playlist)
            if let range = segment.resource.range { try append("#EXT-X-BYTERANGE:\(range)\n", to: &playlist) }
            try append("\(try escapedMedia(segment.resource))\n", to: &playlist)
          }
        }
        try append("#EXT-X-ENDLIST\n", to: &playlist)
        try store(name, playlist)
      }
      var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
      for (index, name) in audioNames.enumerated() {
        let audio = audios[index]
        let audioURL = try YlHlsURLCodec.encode(identities[name]!, kind: .manifest).absoluteString
        let language = audio.language.map { ",LANGUAGE=\"\($0)\"" } ?? ""
        let channels = audio.channels.isEmpty ? "" : ",CHANNELS=\"\(audio.channels)\""
        let characteristics = audio.roles.contains("description") ? ",CHARACTERISTICS=\"public.accessibility.describes-video\"" : ""
        // Only the deterministic default auto-selects: commentary/duplicate languages
        // remain user choices and never compete with a system-language preference.
        let automatic = index == 0 ? "YES" : "NO"
        try append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(audio.audioIdentity)\",DEFAULT=\(automatic),AUTOSELECT=\(automatic)\(language)\(channels)\(characteristics),URI=\"\(audioURL)\"\n", to: &master)
      }
      for (index, name) in videoNames.enumerated() {
        let path = videoPaths[index]
        let video = path.max { ($0.width, $0.height) < ($1.width, $1.height) }!
        let videoURL = try YlHlsURLCodec.encode(identities[name]!, kind: .manifest).absoluteString
        let bandwidth = zip(path, periods).map { $0.bandwidth + ($1.audios.map(\.bandwidth).max() ?? 0) }.max()!
        let codecs = video.codec + (audios.first.map { "," + $0.codec } ?? "")
        let group = audios.isEmpty ? "" : ",AUDIO=\"audio\""
        try append("#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS=\"\(codecs)\",RESOLUTION=\(video.width)x\(video.height)\(group)\n\(videoURL)\n", to: &master)
      }
      try store("master", master)
      return YlDashHlsPresentation(rootURL: identities["master"]!, manifests: registry,
        strippedResources: document.stripped, durationUs: duration, videoCatalog: YlDashVideoCatalog(periods: periods),
        audioCatalog: audios.map { audio in
          YlNativeTrack(id: audio.audioIdentity, kind: .audio, label: audio.audioLabel,
            language: audio.language, codec: audio.codec,
            bitrate: Int(periods.flatMap(\.audios).filter { $0.audioIdentity == audio.audioIdentity }.map(\.bandwidth).max()!))
        })
    } catch let error as YlDashAdmissionError {
      throw error.nativeError
    } catch ProjectionError.invalidSelection {
      throw YlNativeVideoSelection.unsupported
    } catch ProjectionError.noEligibleVideo {
      throw YlAppleVideoConstraints.unsupportedOutput
    } catch {
      // Includes injected URL-closure/native errors: never publish source text.
      throw YlDashBounds.unsupported
    }
  }
}

/// Automatic full-program paths only: anchors are neither fixed requests nor caps.
private enum YlDashVideoPaths {
  private struct Quality: Hashable, Comparable {
    let width: Int64, height: Int64, bandwidth: Int64
    init(_ track: YlDashTrack) {
      width = track.width; height = track.height; bandwidth = track.bandwidth
    }
    static func < (lhs: Quality, rhs: Quality) -> Bool {
      (lhs.width, lhs.height, lhs.bandwidth) < (rhs.width, rhs.height, rhs.bandwidth)
    }
  }
  private static func frameRate(_ value: String?) throws -> String? {
    guard let value = value else { return nil }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 1 || parts.count == 2 else { throw YlDashBounds.unsupported }
    let numerator = try YlDashBounds.number(String(parts[0]))
    let denominator = try parts.count == 2 ? YlDashBounds.number(String(parts[1])) : 1
    guard numerator > 0, denominator > 0 else { throw YlDashBounds.unsupported }
    var a = numerator, b = denominator
    while b != 0 { let remainder = a % b; a = b; b = remainder }
    return "\(numerator / a)/\(denominator / a)"
  }
  static func plan(_ periods: [YlDashPeriod], strictFamily: Bool = false) throws -> [[YlDashTrack]] {
    let first = periods[0].videos
    // Preserve the previously admitted domain, including 64 singleton Periods
    // with varying bandwidth. The new union/family rules apply only after this.
    if !strictFamily, periods.allSatisfy({ period in
      period.videos.count == first.count && zip(period.videos, first).allSatisfy {
        $0.matches($1) && (first.count == 1 || $0.bandwidth == $1.bandwidth)
      }
    }) {
      return first.indices.map { index in periods.map { $0.videos[index] } }
    }
    let reference = first[0]
    let rate = try frameRate(reference.frameRate)
    // The profile byte admits only the established 8-bit AVC profiles. This is
    // declaration validation, not inspection of the encoded media parameters.
    let profile = Int(reference.codec.split(separator: ".")[1].prefix(2), radix: 16)
    guard let profile = profile, [66, 77, 88, 100].contains(profile) else { throw YlDashBounds.unsupported }
    var qualities = Set<Quality>()
    for period in periods {
      var periodQualities = Set<Quality>()
      for track in period.videos {
        guard track.codec == reference.codec, track.roles == reference.roles,
              track.squarePixels, !track.hasRangeDeclaration,
              track.width * reference.height == reference.width * track.height,
              try frameRate(track.frameRate) == rate else { throw YlDashBounds.unsupported }
        let quality = Quality(track)
        guard periodQualities.insert(quality).inserted else { throw YlDashBounds.unsupported }
        qualities.insert(quality)
        guard qualities.count <= YlDashBounds.maxVideoVariants else { throw YlDashBounds.unsupported }
      }
    }
    var paths: [[YlDashTrack]] = []
    var sequences = Set<[Quality]>()
    for anchor in qualities.sorted() {
      // Per-Period tracks are already sorted and aligned before planning.
      let path = periods.map { period in
        period.videos.last { Quality($0) <= anchor } ?? period.videos[0]
      }
      if sequences.insert(path.map(Quality.init)).inserted { paths.append(path) }
    }
    return paths
  }
}
