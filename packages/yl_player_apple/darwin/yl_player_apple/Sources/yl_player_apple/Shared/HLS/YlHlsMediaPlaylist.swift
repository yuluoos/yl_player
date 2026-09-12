import Foundation

struct YlHlsMediaSegment: Equatable {
  let url: URL
  let startUs: Int64
  let durationUs: Int64
}

struct YlHlsMediaPlaylist: Equatable {
  let segments: [YlHlsMediaSegment]
  let durationUs: Int64

  static func parse(data: Data, baseURL: URL) throws -> Self {
    guard let text = String(data: data, encoding: .utf8) else {
      throw unsupported("manifest.utf8")
    }
    let lines = text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard lines.first(where: { !$0.isEmpty }) == "#EXTM3U",
          lines.contains("#EXT-X-ENDLIST"),
          !lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }),
          !lines.contains(where: { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }),
          !lines.contains(where: { $0.hasPrefix("#EXT-X-MAP:") }),
          !lines.contains(where: { $0.hasPrefix("#EXT-X-BYTERANGE:") }),
          !lines.contains("#EXT-X-DISCONTINUITY"),
          !lines.contains(where: {
            $0.hasPrefix("#EXT-X-KEY:") && !$0.contains("METHOD=NONE")
          }) else {
      throw unsupported("manifest.features")
    }

    var segments = [YlHlsMediaSegment]()
    var pendingDurationUs: Int64?
    var startUs: Int64 = 0
    for line in lines {
      if line.hasPrefix("#EXTINF:") {
        let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1)[0]
        guard let seconds = Double(value), seconds.isFinite, seconds > 0 else {
          throw unsupported("manifest.duration")
        }
        let micros = seconds * 1_000_000
        guard micros <= Double(Int64.max) else {
          throw unsupported("manifest.duration")
        }
        pendingDurationUs = Int64(micros.rounded())
        continue
      }
      guard !line.isEmpty, !line.hasPrefix("#"), let durationUs = pendingDurationUs,
            let url = URL(string: line, relativeTo: baseURL)?.absoluteURL,
            sameOrigin(url, baseURL),
            ["ts", "m2ts"].contains(url.pathExtension.lowercased()) else {
        if !line.isEmpty, !line.hasPrefix("#"), pendingDurationUs != nil {
          throw unsupported("manifest.segment")
        }
        continue
      }
      segments.append(YlHlsMediaSegment(
        url: url,
        startUs: startUs,
        durationUs: durationUs
      ))
      let next = startUs.addingReportingOverflow(durationUs)
      guard !next.overflow else { throw unsupported("manifest.timeline") }
      startUs = next.partialValue
      pendingDurationUs = nil
    }
    guard !segments.isEmpty, pendingDurationUs == nil else {
      throw unsupported("manifest.empty")
    }
    return Self(segments: segments, durationUs: startUs)
  }

  func segmentIndex(containing positionUs: Int64) -> Int {
    let target = max(0, positionUs)
    var low = 0
    var high = segments.count
    while low < high {
      let middle = low + (high - low) / 2
      if segments[middle].startUs <= target {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return max(0, min(segments.count - 1, low - 1))
  }

  private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && effectivePort(lhs) == effectivePort(rhs)
  }

  private static func effectivePort(_ url: URL) -> Int? {
    url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
  }

  private static func unsupported(_ diagnostic: String) -> NativePlayerError {
    NativePlayerError(
      category: "container",
      code: "container.hls_managed_unsupported",
      message: "This HLS playlist cannot use managed MPEG-TS playback.",
      diagnostic: diagnostic
    )
  }
}
