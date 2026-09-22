import Foundation

struct YlDashHlsPresentation {
  let rootURL: URL
  let manifests: [URL: Data]
  let strippedResources: Set<String>
  let durationUs: Int64
}

enum YlDashHlsCompiler {
  static func compile(data: Data, finalManifestURL: URL, sourceURL: URL,
    credentialsStripped: Bool, manifestURL: (String) throws -> URL,
    mediaURL: (URL, Bool) throws -> URL) throws -> YlDashHlsPresentation {
    do {
      let document = YlDashDocument(source: sourceURL)
      let (periods, duration) = try document.parse(data, final: finalManifestURL,
        credentialsStripped: credentialsStripped)
      let names = periods[0].audio == nil ? ["master", "video"] : ["master", "video", "audio"]
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
        let tracks = periods.map { name == "video" ? $0.video : $0.audio! }
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
      let video = periods[0].video
      let audio = periods[0].audio
      let videoURL = try YlHlsURLCodec.encode(identities["video"]!, kind: .manifest).absoluteString
      var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
      if let audioID = identities["audio"] {
        let audioURL = try YlHlsURLCodec.encode(audioID, kind: .manifest).absoluteString
        try append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audioURL)\"\n", to: &master)
      }
      let bandwidth = periods.map { $0.video.bandwidth + ($0.audio?.bandwidth ?? 0) }.max()!
      let codecs = video.codec + (audio.map { "," + $0.codec } ?? "")
      let group = audio == nil ? "" : ",AUDIO=\"audio\""
      try append("#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS=\"\(codecs)\",RESOLUTION=\(video.width)x\(video.height)\(group)\n\(videoURL)\n", to: &master)
      try store("master", master)
      return YlDashHlsPresentation(rootURL: identities["master"]!, manifests: registry,
        strippedResources: document.stripped, durationUs: duration)
    } catch {
      // Includes injected URL-closure/native errors: never publish source text.
      throw YlDashBounds.unsupported
    }
  }
}
