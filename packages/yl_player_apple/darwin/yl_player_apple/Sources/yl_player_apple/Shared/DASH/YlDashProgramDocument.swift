import Foundation
import CryptoKit

/// Resource/timing description only. Declared codecs do not prove decoder support.
struct YlDashProgram {
  let timeline: YlDashProgramTimeline
  let periods: [Period]
  struct Period { let tracks: [Track] }
  struct Track {
    enum Kind: String { case video, audio, text }
    let id: String
    let kind: Kind
    let codec: String
    let language: String?
    let roles: [String]
    let bandwidth: Int64
    let width: Int64
    let height: Int64
    let sampleRate: Int64
    let channels: String
    /// Original format/range declarations are carried to decoder admission.
    let attributes: [String: String]
    let descriptors: [[String: String]]
    let offset: YlDashProgramTime
    let initialization: Resource?
    let segments: [Segment]
  }
  struct Resource {
    struct Candidate: Hashable { let url: URL; let credentialsStripped: Bool }
    struct ByteRange: Equatable { let start: Int64; let length: Int64 }
    let candidates: [Candidate]
    let range: ByteRange?
  }
  struct Segment {
    let start: YlDashProgramTime
    let duration: YlDashProgramTime
    let resource: Resource
  }
}

/// Network-free bounded admission for the precise programme path. It does not
/// relax YlDashDocument's separate HLS projection rules.
enum YlDashProgramDocument {
  static func indexRequests(_ data: Data, source: URL, final: URL, credentialsStripped: Bool = false) throws -> [YlDashIndexRequest] {
    try Builder(source: source, indexes: [:]).indexRequests(data, final: final, credentialsStripped: credentialsStripped)
  }
  /// One SegmentBase intent contains all BaseURL alternatives, sharing budgets.
  static func indexResources(_ data: Data, source: URL, final: URL, credentialsStripped: Bool = false) throws -> [YlDashProgram.Resource] {
    try Builder(source: source, indexes: [:]).indexResources(data, final: final, credentialsStripped: credentialsStripped)
  }
  static func parse(_ data: Data, source: URL, final: URL, credentialsStripped: Bool = false,
                    indexes: [YlDashIndexRequest: YlDashResolvedIndex] = [:]) throws -> YlDashProgram {
    try Builder(source: source, indexes: indexes).parse(data, final: final, credentialsStripped: credentialsStripped)
  }

  private final class Builder {
    typealias Time = YlDashProgramTime
    typealias Resource = YlDashProgram.Resource
    let source: URL
    let indexes: [YlDashIndexRequest: YlDashResolvedIndex]
    var uriUnits = 0, segmentCount = 0, representationCount = 0
    init(source: URL, indexes: [YlDashIndexRequest: YlDashResolvedIndex]) { self.source = source; self.indexes = indexes }

    func indexRequests(_ data: Data, final: URL, credentialsStripped: Bool) throws -> [YlDashIndexRequest] {
      var seen = Set<YlDashIndexRequest>()
      return try indexResources(data, final: final, credentialsStripped: credentialsStripped).flatMap { resource in
        resource.candidates.compactMap { candidate in
          let request = YlDashIndexRequest(url: candidate.url, start: resource.range!.start,
            length: Int(resource.range!.length), credentialsStripped: candidate.credentialsStripped)
          return seen.insert(request).inserted ? request : nil
        }
      }
    }

    func indexResources(_ data: Data, final: URL, credentialsStripped: Bool) throws -> [Resource] {
      _ = try YlDashBounds.url(source.absoluteString); _ = try YlDashBounds.url(final.absoluteString)
      let root = try YlDashXMLReader.parse(data, allowSegmentBase: true)
      guard root.attributes["type", default: "static"] == "static" else { throw YlDashAdmissionError.dynamicManifest }
      let periods = root.nodes("Period")
      guard !periods.isEmpty, periods.count <= 64 else { throw YlDashProgramError.limitExceeded }
      let locations = try bases(root, [.init(url: final, credentialsStripped: credentialsStripped || YlRequestOrigin(url: final) != YlRequestOrigin(url: source))])
      var result: [Resource] = [], totalBytes = 0
      for period in periods {
        let periodBases = try bases(period, locations)
        for adaptation in period.nodes("AdaptationSet") {
          let adaptationBases = try bases(adaptation, periodBases)
          for representation in adaptation.nodes("Representation") {
            representationCount += 1
            guard representationCount <= YlDashBounds.maxRepresentations else { throw YlDashProgramError.limitExceeded }
            let info = try addressing([root, period, adaptation, representation])
            guard info.mode == "SegmentBase" else { continue }
            guard let rawRange = info.attributes["indexRange"], info.initialization != nil else { throw YlDashBounds.unsupported }
            let resource = try resource(nil, rawRange, bases(representation, adaptationBases))
            guard let range = resource.range, range.length <= YlDashSidx.maxIndexBytes else { throw YlDashProgramError.limitExceeded }
            guard range.length <= 4 * 1024 * 1024 - totalBytes else { throw YlDashProgramError.limitExceeded }
            totalBytes += Int(range.length); result.append(resource)
          }
        }
      }
      return result
    }

    func parse(_ data: Data, final: URL, credentialsStripped: Bool) throws -> YlDashProgram {
      _ = try YlDashBounds.url(source.absoluteString); _ = try YlDashBounds.url(final.absoluteString)
      let root = try YlDashXMLReader.parse(data, allowSegmentBase: true)
      guard root.attributes["type", default: "static"] == "static" else { throw YlDashAdmissionError.dynamicManifest }
      let nodes = root.nodes("Period")
      guard !nodes.isEmpty, nodes.count <= 64 else { throw YlDashProgramError.limitExceeded }
      let total = try root.attributes["mediaPresentationDuration"].map(duration)
      let location = try bases(root, [.init(url: final, credentialsStripped: credentialsStripped || YlRequestOrigin(url: final) != YlRequestOrigin(url: source))])
      var timing: [YlDashProgramTimeline.Period] = [], periods: [YlDashProgram.Period] = []
      var cursor = try Time(0)
      for (index, node) in nodes.enumerated() {
        let start = try node.attributes["start"].map(duration) ?? cursor
        let next = try (index + 1 < nodes.count ? nodes[index + 1].attributes["start"] : nil).map(duration)
        let declared = try node.attributes["duration"].map(duration)
        let span = try declared ?? next.map { try $0.subtracting(start) } ?? (index + 1 == nodes.count ? total.map { try $0.subtracting(start) } : nil)
        if let span, span.numerator <= 0 { throw YlDashProgramError.invalidPeriod }
        let periodBase = try bases(node, location)
        var tracks: [YlDashProgram.Track] = []
        for adaptation in node.nodes("AdaptationSet") {
          let adaptationBase = try bases(adaptation, periodBase)
          let representations = adaptation.nodes("Representation")
          guard !representations.isEmpty, representations.count <= YlDashBounds.maxVideoVariants else { throw YlDashProgramError.limitExceeded }
          for representation in representations {
            representationCount += 1
            guard representationCount <= YlDashBounds.maxRepresentations else { throw YlDashProgramError.limitExceeded }
            let ancestors = [root, node, adaptation, representation]
            var attributes: [String: String] = [:]
            for parent in ancestors { attributes.merge(parent.attributes) { _, new in new } }
            // Representation identity is local; AdaptationSet/Period ids are
            // content identity and must not fill a missing template token.
            attributes["id"] = representation.attributes["id"]
            let track = try build(ancestors, attributes, bases(representation, adaptationBase), span)
            guard !tracks.contains(where: { $0.id == track.id }) else { throw YlDashBounds.unsupported }
            tracks.append(track)
          }
        }
        guard tracks.contains(where: { $0.kind == .video }), tracks.filter({ $0.kind == .audio }).count <= YlDashBounds.maxAudioTracks else { throw YlDashBounds.unsupported }
        let resolved: Time
        if let span { resolved = span }
        else {
          // Only finite segment references, all AV tracks agreeing, establish a
          // missing duration; text cues cannot establish programme length.
          let ends = try tracks.filter { $0.kind != .text }.map { track -> Time in
            guard let last = track.segments.last else { throw YlDashProgramError.unresolvedPeriod }
            return try last.start.adding(last.duration).subtracting(track.offset)
          }
          guard let first = ends.first, first.numerator > 0, ends.allSatisfy({ $0 == first }) else { throw YlDashProgramError.unresolvedPeriod }
          resolved = first
        }
        cursor = try start.adding(resolved)
        timing.append(.init(start: start, duration: resolved)); periods.append(.init(tracks: tracks))
      }
      let timeline = try YlDashProgramTimeline(periods: timing)
      guard total == nil || total == timeline.duration else { throw YlDashProgramError.invalidPeriod }
      return .init(timeline: timeline, periods: periods)
    }

    private func duration(_ value: String) throws -> Time {
      guard value.utf8.count <= 128 else { throw YlDashProgramError.limitExceeded }
      let regex = try NSRegularExpression(pattern: #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)(?:\.(\d{1,18}))?S)?)?$"#)
      let ns = value as NSString
      guard let m = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)), (1...4).contains(where: { m.range(at: $0).location != NSNotFound }) else { throw YlDashProgramError.invalidTime }
      var result = try Time(0)
      for (index, multiplier) in [(1, Int64(86400)), (2, 3600), (3, 60), (4, 1)] where m.range(at: index).location != NSNotFound {
        let seconds = try YlDashBounds.multiply(YlDashBounds.number(ns.substring(with: m.range(at: index))), multiplier)
        result = try result.adding(Time(seconds))
      }
      if m.range(at: 5).location != NSNotFound {
        let digits = ns.substring(with: m.range(at: 5)), scale = Int64("1" + String(repeating: "0", count: digits.count))!
        result = try result.adding(Time(YlDashBounds.number(digits), scale))
      }
      return result
    }

    private func record(_ reference: String, parent: Resource.Candidate) throws -> Resource.Candidate {
      let url = try YlDashBounds.url(reference, relativeTo: parent.url)
      let units = url.absoluteString.utf16.count
      guard units <= YlDashBounds.maxTotalURI - uriUnits else { throw YlDashProgramError.limitExceeded }
      uriUnits += units
      return .init(url: url, credentialsStripped: parent.credentialsStripped || YlRequestOrigin(url: url) != YlRequestOrigin(url: source))
    }
    private func bases(_ node: YlDashNode, _ parents: [Resource.Candidate]) throws -> [Resource.Candidate] {
      let declarations = node.nodes("BaseURL")
      if declarations.isEmpty { return parents }
      guard declarations.count <= 16, parents.count <= 16 / declarations.count else { throw YlDashProgramError.limitExceeded }
      var result: [Resource.Candidate] = []
      for parent in parents {
        for declaration in declarations {
          let candidate = try record(declaration.text.trimmingCharacters(in: .whitespacesAndNewlines), parent: parent)
          if !result.contains(candidate) { result.append(candidate) }
        }
      }
      return result
    }
    private func resource(_ name: String?, _ rawRange: String?, _ locations: [Resource.Candidate]) throws -> Resource {
      let range: Resource.ByteRange?
      if let rawRange {
        let parts = rawRange.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw YlDashBounds.unsupported }
        let start = try YlDashBounds.number(String(parts[0])), end = try YlDashBounds.number(String(parts[1]))
        guard end >= start else { throw YlDashBounds.unsupported }
        range = .init(start: start, length: try YlDashBounds.add(end - start, 1))
      } else { range = nil }
      return Resource(candidates: try locations.map { try record(name.flatMap { $0.isEmpty ? nil : $0 } ?? $0.url.absoluteString, parent: $0) }, range: range)
    }

    private struct Address {
      var mode: String?
      var attributes: [String: String] = [:]
      var timeline: YlDashNode?
      var initialization: YlDashNode?
      var urls: [YlDashNode] = []
    }
    private func addressing(_ ancestors: [YlDashNode]) throws -> Address {
      var value = Address()
      for ancestor in ancestors {
        for mode in ["SegmentTemplate", "SegmentList", "SegmentBase"] {
          guard let node = try ancestor.one(mode) else { continue }
          guard value.mode == nil || value.mode == mode else { throw YlDashBounds.unsupported }
          value.mode = mode; value.attributes.merge(node.attributes) { _, new in new }
          if let timeline = try node.one("SegmentTimeline") { value.timeline = timeline }
          if let initialization = try node.one("Initialization") { value.initialization = initialization }
          if !node.nodes("SegmentURL").isEmpty { value.urls = node.nodes("SegmentURL") }
        }
      }
      return value
    }

    private func build(_ ancestors: [YlDashNode], _ attrs: [String: String], _ locations: [Resource.Candidate], _ span: Time?) throws -> YlDashProgram.Track {
      let mime = attrs["mimeType", default: ""]
      let rawKind = attrs["contentType"] ?? (mime.hasPrefix("video/") ? "video" : mime.hasPrefix("audio/") ? "audio" : ["text/vtt", "application/ttml+xml"].contains(mime) || attrs["codecs"] == "wvtt" || attrs["codecs"]?.hasPrefix("stpp") == true ? "text" : "")
      guard let kind = YlDashProgram.Track.Kind(rawValue: rawKind) else { throw YlDashBounds.unsupported }
      let codec = attrs["codecs", default: mime]
      guard !codec.isEmpty, codec.utf8.count <= 128 else { throw YlDashBounds.unsupported }
      let width = try YlDashBounds.number(attrs["width"], default: 0), height = try YlDashBounds.number(attrs["height"], default: 0)
      let bandwidth = try YlDashBounds.number(attrs["bandwidth"], default: kind == .text ? 0 : nil)
      let rate = try YlDashBounds.number(attrs["audioSamplingRate"], default: 0)
      guard bandwidth <= 1_000_000_000, rate <= 768000, width <= 65535, height <= 65535,
            kind != .video || (width > 0 && height > 0) else { throw YlDashBounds.unsupported }
      let language = attrs["lang"]
      if let language, !YlDashBounds.audioLanguage(language) { throw YlDashBounds.unsupported }
      var roles: [String] = [], channels = ""
      for node in ancestors {
        for role in node.nodes("Role") {
          guard role.attributes["schemeIdUri", default: "urn:mpeg:dash:role:2011"] == "urn:mpeg:dash:role:2011", let role = role.attributes["value"], ["main", "alternate", "supplementary", "commentary", "dub", "caption", "subtitle", "description", "enhanced-audio-intelligibility", "emergency"].contains(role) else { throw YlDashBounds.unsupported }
          roles.append(role)
        }
        if let channel = try node.one("AudioChannelConfiguration") {
          guard channel.attributes["schemeIdUri"] == "urn:mpeg:dash:23003:3:audio_channel_configuration:2011" else { throw YlDashBounds.unsupported }
          let count = try YlDashBounds.number(channel.attributes["value"])
          guard (1...8).contains(count) else { throw YlDashBounds.unsupported }; channels = String(count)
        }
      }
      roles = Array(Set(roles)).sorted()
      let content = ancestors[2].attributes["id", default: ""]
      guard content.utf8.count <= 128 else { throw YlDashBounds.unsupported }
      let fields = [content, language?.lowercased() ?? "", roles.joined(separator: ","), codec, String(rate), channels] + (kind == .video ? [String(width), String(height), String(bandwidth)] : [])
      let id = "dash-\(kind.rawValue)-" + SHA256.hash(data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
      let address = try addressing(ancestors)
      let scale = try YlDashBounds.number(address.attributes["timescale"], default: 1)
      let offsetTicks = try YlDashBounds.number(address.attributes["presentationTimeOffset"], default: 0)
      let offset = try Time(offsetTicks, scale)
      var initialization: Resource?, segments: [YlDashProgram.Segment] = []
      if address.mode == nil {
        guard kind == .text, let span else { throw YlDashBounds.unsupported }
        segmentCount += 1; guard segmentCount <= YlDashBounds.maxSegments else { throw YlDashProgramError.limitExceeded }
        segments = [.init(start: offset, duration: span, resource: try resource(nil, nil, locations))]
      } else if address.mode == "SegmentBase" {
        guard let initializationNode = address.initialization, let rawRange = address.attributes["indexRange"] else { throw YlDashBounds.unsupported }
        initialization = try resource(initializationNode.attributes["sourceURL"], initializationNode.attributes["range"], locations)
        let indexResource = try resource(nil, rawRange, locations)
        let range = indexResource.range!
        guard range.length <= YlDashSidx.maxIndexBytes else { throw YlDashProgramError.limitExceeded }
        let available = indexResource.candidates.compactMap { candidate in
          indexes[.init(url: candidate.url, start: range.start, length: Int(range.length), credentialsStripped: candidate.credentialsStripped)]
        }
        guard let resolved = available.first, resolved.index.earliestPresentationTimeTicks <= UInt64(Int64.max) else { throw YlDashProgramError.unresolvedPeriod }
        var cursor = Int64(resolved.index.earliestPresentationTimeTicks)
        for reference in resolved.index.references {
          guard reference.durationTicks <= UInt64(Int64.max), reference.offset <= UInt64(Int64.max), reference.length <= UInt64(Int64.max),
                reference.startsWithSAP, reference.sapType == 1, reference.sapDeltaTicks == 0,
                reference.offset <= UInt64(max(0, resolved.resourceLength)), reference.length <= UInt64(max(0, resolved.resourceLength)) - reference.offset else { throw YlDashBounds.unsupported }
          segmentCount += 1; guard segmentCount <= YlDashBounds.maxSegments else { throw YlDashProgramError.limitExceeded }
          let candidate = try record(resolved.effectiveURL.absoluteString, parent: .init(url: source, credentialsStripped: resolved.credentialsStripped || indexResource.candidates.contains(where: { $0.credentialsStripped })))
          segments.append(.init(start: try Time(cursor, Int64(resolved.index.timescale)), duration: try Time(Int64(reference.durationTicks), Int64(resolved.index.timescale)), resource: .init(candidates: [candidate], range: .init(start: Int64(reference.offset), length: Int64(reference.length)))))
          cursor = try YlDashBounds.add(cursor, Int64(reference.durationTicks))
        }
      } else {
        let samples = try samples(address, scale: scale, offset: offsetTicks, span: span)
        if address.mode == "SegmentTemplate" {
          if let name = address.attributes["initialization"] { initialization = try resource(expand(name, attrs: attrs, number: nil, time: nil), nil, locations) }
          guard let media = address.attributes["media"], kind == .text || initialization != nil else { throw YlDashBounds.unsupported }
          let first = try YlDashBounds.number(address.attributes["startNumber"], default: 1)
          for (index, sample) in samples.enumerated() {
            let name = try expand(media, attrs: attrs, number: YlDashBounds.add(first, Int64(index)), time: sample.0)
            segments.append(.init(start: try Time(sample.0, scale), duration: try Time(sample.1, scale), resource: try resource(name, nil, locations)))
          }
        } else {
          if let node = address.initialization { initialization = try resource(node.attributes["sourceURL"], node.attributes["range"], locations) }
          guard samples.count == address.urls.count, kind == .text || initialization != nil else { throw YlDashBounds.unsupported }
          for (index, node) in address.urls.enumerated() {
            segments.append(.init(start: try Time(samples[index].0, scale), duration: try Time(samples[index].1, scale), resource: try resource(node.attributes["media"], node.attributes["mediaRange"], locations)))
          }
        }
      }
      guard !segments.isEmpty else { throw YlDashBounds.unsupported }
      return .init(id: id, kind: kind, codec: codec, language: language, roles: roles, bandwidth: bandwidth, width: width, height: height, sampleRate: rate, channels: channels, attributes: attrs, descriptors: ancestors.flatMap { $0.nodes("SupplementalProperty").map(\.attributes) }, offset: offset, initialization: initialization, segments: segments)
    }

    private func samples(_ address: Address, scale: Int64, offset: Int64, span: Time?) throws -> [(Int64, Int64)] {
      var samples: [(Int64, Int64)] = []
      func append(_ start: Int64, _ duration: Int64, _ count: Int64) throws {
        guard start >= 0, duration > 0, count > 0, count <= Int64(YlDashBounds.maxSegments - segmentCount) else { throw YlDashProgramError.limitExceeded }
        _ = try YlDashBounds.add(start, YlDashBounds.multiply(duration, count))
        segmentCount += Int(count)
        for index in 0..<count { samples.append((try YlDashBounds.add(start, YlDashBounds.multiply(index, duration)), duration)) }
      }
      if let timeline = address.timeline {
        let entries = timeline.nodes("S")
        guard !entries.isEmpty, entries.count == timeline.children.count else { throw YlDashBounds.unsupported }
        var cursor: Int64 = 0
        for (index, entry) in entries.enumerated() {
          let start = try YlDashBounds.number(entry.attributes["t"], default: cursor), d = try YlDashBounds.number(entry.attributes["d"])
          guard d > 0, samples.last.map({ start > $0.0 }) ?? true else { throw YlDashBounds.unsupported }
          let count: Int64
          if entry.attributes["r"] == "-1" {
            let boundary: Int64
            if index + 1 < entries.count, let next = entries[index + 1].attributes["t"] { boundary = try YlDashBounds.number(next) }
            else if let span { boundary = try span.adding(Time(offset, scale)).converted(to: scale, rounding: .ceil) }
            else { throw YlDashProgramError.unresolvedPeriod }
            guard boundary > start else { throw YlDashBounds.unsupported }
            count = (boundary - start) / d + ((boundary - start) % d == 0 ? 0 : 1)
          } else { count = try YlDashBounds.add(YlDashBounds.number(entry.attributes["r"], default: 0), 1) }
          try append(start, d, count); cursor = try YlDashBounds.add(start, YlDashBounds.multiply(d, count))
        }
      } else {
        let d = try YlDashBounds.number(address.attributes["duration"])
        guard d > 0 else { throw YlDashBounds.unsupported }
        let count: Int64
        if address.mode == "SegmentList" { count = Int64(address.urls.count) }
        else if let span {
          let end = try span.adding(Time(offset, scale)).converted(to: scale, rounding: .ceil)
          count = end / d + (end % d == 0 ? 0 : 1)
        } else { throw YlDashProgramError.unresolvedPeriod }
        try append(0, d, count)
      }
      return samples
    }

    private func expand(_ value: String, attrs: [String: String], number: Int64?, time: Int64?) throws -> String {
      guard value.utf16.count <= YlDashBounds.maxURI else { throw YlDashProgramError.limitExceeded }
      let parts = value.components(separatedBy: "$")
      guard parts.count % 2 == 1 else { throw YlDashBounds.unsupported }
      var output = ""
      for (index, part) in parts.enumerated() {
        let addition: String
        if index % 2 == 0 { addition = part }
        else if part.isEmpty { addition = "$" }
        else if part == "RepresentationID" { guard let id = attrs["id"], !id.isEmpty else { throw YlDashBounds.unsupported }; addition = id }
        else {
          let fields = part.components(separatedBy: "%")
          guard fields.count <= 2 else { throw YlDashBounds.unsupported }
          let value: Int64?
          switch fields[0] { case "Number": value = number; case "Time": value = time; case "Bandwidth": value = try YlDashBounds.number(attrs["bandwidth"]); default: value = nil }
          guard let value else { throw YlDashBounds.unsupported }
          var width = 0
          if fields.count == 2 {
            let format = fields[1]
            guard format.hasPrefix("0"), format.hasSuffix("d"), format.count <= 4 else { throw YlDashBounds.unsupported }
            let n = try YlDashBounds.number(String(format.dropFirst().dropLast()))
            guard (1...20).contains(n) else { throw YlDashBounds.unsupported }; width = Int(n)
          }
          let digits = String(value); addition = String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        guard addition.utf16.count <= YlDashBounds.maxURI - output.utf16.count else { throw YlDashProgramError.limitExceeded }
        output += addition
      }
      return output
    }
  }
}
