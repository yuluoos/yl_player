import Foundation

/// Deliberately bounded, network-free XML tree. No XML text reaches diagnostics.
final class YlDashNode {
  let name: String
  let attributes: [String: String]
  var children: [YlDashNode] = []
  var text = ""
  init(_ name: String, _ attributes: [String: String]) {
    self.name = name; self.attributes = attributes
  }
  func nodes(_ name: String) -> [YlDashNode] { children.filter { $0.name == name } }
  func one(_ name: String) throws -> YlDashNode? {
    let matches = nodes(name)
    guard matches.count <= 1 else { throw YlDashBounds.unsupported }
    return matches.first
  }
}

enum YlDashBounds {
  static let maxDocument = 2 * 1024 * 1024
  static let maxSegments = 100_000
  static let maxURI = 8192
  static let maxTotalURI = 4 * 1024 * 1024
  static var unsupported: NativePlayerError {
    NativePlayerError(category: "container", code: "container.unsupported",
      message: "The DASH presentation is unsupported.")
  }
  static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
    let r = a.addingReportingOverflow(b)
    guard !r.overflow else { throw unsupported }; return r.partialValue
  }
  static func multiply(_ a: Int64, _ b: Int64) throws -> Int64 {
    let r = a.multipliedReportingOverflow(by: b)
    guard !r.overflow else { throw unsupported }; return r.partialValue
  }
  static func number(_ value: String?, default fallback: Int64? = nil) throws -> Int64 {
    guard let value = value else {
      guard let fallback = fallback else { throw unsupported }; return fallback
    }
    guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
          let result = Int64(value) else { throw unsupported }
    return result
  }
  static func duration(_ value: String) throws -> Int64 {
    // Fixed day/hour/minute/second durations only; no calendar or floating arithmetic.
    let pattern = #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)(?:\.(\d{1,6}))?S)?)?$"#
    let regex = try NSRegularExpression(pattern: pattern)
    let ns = value as NSString
    guard let m = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)),
          (1...4).contains(where: { m.range(at: $0).location != NSNotFound }) else { throw unsupported }
    var seconds: Int64 = 0
    for (i, multiplier) in [(1, Int64(86400)), (2, 3600), (3, 60), (4, 1)] {
      if m.range(at: i).location != NSNotFound {
        seconds = try add(seconds, multiply(number(ns.substring(with: m.range(at: i))), multiplier))
      }
    }
    var us = try multiply(seconds, 1_000_000)
    if m.range(at: 5).location != NSNotFound {
      let fraction = ns.substring(with: m.range(at: 5))
      us = try add(us, number(fraction + String(repeating: "0", count: 6 - fraction.count)))
    }
    return us
  }
  static func url(_ value: String, relativeTo base: URL? = nil) throws -> URL {
    guard !value.isEmpty, value.utf16.count <= maxURI,
          !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          let result = URL(string: value, relativeTo: base)?.absoluteURL,
          result.absoluteString.utf16.count <= maxURI,
          ["http", "https"].contains(result.scheme?.lowercased() ?? ""),
          result.host?.isEmpty == false, result.user == nil, result.password == nil,
          result.fragment == nil else { throw unsupported }
    return result
  }
}

private final class YlDashXMLReader: NSObject, XMLParserDelegate {
  // Addressing/timing nodes are a closed subset. Validate each declaration before
  // inheritance, so an unsupported ancestor cannot disappear under an override.
  private static let segmentAttributes: [String: Set<String>] = [
    "SegmentTemplate": ["timescale", "presentationTimeOffset", "duration", "startNumber", "initialization", "media"],
    "SegmentList": ["timescale", "presentationTimeOffset", "duration", "startNumber"],
    "SegmentTimeline": [],
    "S": ["t", "d", "r"],
  ]
  var root: YlDashNode?
  var stack: [YlDashNode] = []
  var count = 0
  var invalid = false
  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String]) {
    count += 1
    let forbidden: Set<String> = ["ContentProtection", "SegmentBase", "UTCTiming", "Location",
      "PatchLocation", "ContentSteering", "EssentialProperty", "Subset", "SubRepresentation",
      "SegmentURLIndex", "RepresentationIndex", "BitstreamSwitching"]
    guard count <= 100_000, stack.count < 64, !forbidden.contains(name),
          namespaceURI == nil || namespaceURI == "" || namespaceURI == "urn:mpeg:dash:schema:mpd:2011",
          !attributes.keys.contains(where: { $0.contains(":") && !$0.hasPrefix("xmlns") }),
          !attributes.keys.contains(where: { ["availabilityTimeOffset", "availabilityTimeComplete", "index", "indexRange"].contains($0) }) else {
      invalid = true; parser.abortParsing(); return
    }
    if let allowed = Self.segmentAttributes[name],
       !attributes.keys.allSatisfy({ allowed.contains($0) || $0 == "xmlns" || $0.hasPrefix("xmlns:") }) {
      invalid = true; parser.abortParsing(); return
    }
    let node = YlDashNode(name, attributes)
    if let parent = stack.last { parent.children.append(node) }
    else if root == nil { root = node }
    else { invalid = true; parser.abortParsing(); return }
    stack.append(node)
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    // Only BaseURL carries meaningful text. Input byte cap bounds all other text.
    if stack.last?.name == "BaseURL" {
      guard (stack.last?.text.utf16.count ?? 0) + string.utf16.count <= YlDashBounds.maxURI else {
        invalid = true; parser.abortParsing(); return
      }
      stack.last?.text += string
    }
  }
  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    if !stack.isEmpty { stack.removeLast() }
  }
  static func parse(_ data: Data) throws -> YlDashNode {
    guard data.count <= YlDashBounds.maxDocument,
          let text = String(data: data, encoding: .utf8),
          !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw YlDashBounds.unsupported }
    let reader = YlDashXMLReader()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = reader
    guard parser.parse(), !reader.invalid, let root = reader.root, root.name == "MPD" else { throw YlDashBounds.unsupported }
    return root
  }
}

struct YlDashResource {
  let url: URL
  let range: String?
}
struct YlDashSegment {
  let resource: YlDashResource
  let ticks: Int64
  let scale: Int64
}
struct YlDashTrack {
  let codec: String
  let width: Int64
  let height: Int64
  let samplingRate: Int64
  let channels: String
  let roles: [String]
  let bandwidth: Int64
  let initialization: YlDashResource
  let segments: [YlDashSegment]
  func matches(_ other: YlDashTrack) -> Bool {
    codec == other.codec && width == other.width && height == other.height
      && samplingRate == other.samplingRate && channels == other.channels && roles == other.roles
  }
}
struct YlDashPeriod {
  let video: YlDashTrack
  let audio: YlDashTrack?
}

final class YlDashDocument {
  let source: URL
  var stripped = Set<String>()
  private var uriUnits = 0
  private var segmentCount = 0
  init(source: URL) { self.source = source }
  private func record(_ value: String, base: URL, inherited: Bool, isResource: Bool = true) throws -> URL {
    let url = try YlDashBounds.url(value, relativeTo: base)
    let units = url.absoluteString.utf16.count
    guard units <= YlDashBounds.maxTotalURI - uriUnits else { throw YlDashBounds.unsupported }
    uriUnits += units
    if isResource && (inherited || YlRequestOrigin(url: url) != YlRequestOrigin(url: source)) { stripped.insert(url.absoluteString) }
    return url
  }
  private func base(_ node: YlDashNode, _ parent: (URL, Bool)) throws -> (URL, Bool) {
    guard let element = try node.one("BaseURL") else { return parent }
    let url = try record(element.text.trimmingCharacters(in: .whitespacesAndNewlines), base: parent.0, inherited: parent.1, isResource: false)
    return (url, parent.1 || YlRequestOrigin(url: url) != YlRequestOrigin(url: source))
  }
  func parse(_ data: Data, final: URL, credentialsStripped: Bool) throws -> ([YlDashPeriod], Int64) {
    _ = try YlDashBounds.url(source.absoluteString); _ = try YlDashBounds.url(final.absoluteString)
    let root = try YlDashXMLReader.parse(data)
    guard root.attributes["type", default: "static"] == "static" else { throw YlDashBounds.unsupported }
    let total = try root.attributes["mediaPresentationDuration"].map(YlDashBounds.duration)
    let roots = try base(root, (final, credentialsStripped || YlRequestOrigin(url: final) != YlRequestOrigin(url: source)))
    let periods = root.nodes("Period")
    guard !periods.isEmpty, periods.count <= 64 else { throw YlDashBounds.unsupported }
    var end: Int64 = 0
    var result: [YlDashPeriod] = []
    for (index, period) in periods.enumerated() {
      let start = try period.attributes["start"].map(YlDashBounds.duration) ?? end
      guard start == end else { throw YlDashBounds.unsupported }
      let nextStart = try (index + 1 < periods.count ? periods[index + 1].attributes["start"] : nil).map(YlDashBounds.duration)
      let duration = try period.attributes["duration"].map(YlDashBounds.duration)
        ?? nextStart.map { $0 - start } ?? (index + 1 == periods.count ? total.map { $0 - start } : nil)
      guard let duration = duration, duration > 0 else { throw YlDashBounds.unsupported }
      end = try YlDashBounds.add(start, duration)
      let periodBase = try base(period, roots)
      var video: YlDashTrack?; var audio: YlDashTrack?
      for adaptation in period.nodes("AdaptationSet") {
        let representations = adaptation.nodes("Representation")
        guard representations.count == 1 else { throw YlDashBounds.unsupported }
        let representation = representations[0]
        let ancestors = [root, period, adaptation, representation]
        var attributes: [String: String] = [:]
        for node in [adaptation, representation] { attributes.merge(node.attributes) { _, new in new } }
        let mime = attributes["mimeType"]
        let kind = attributes["contentType"] ?? (mime == "video/mp4" ? "video" : mime == "audio/mp4" ? "audio" : "")
        guard kind == "video" || kind == "audio", mime == nil || mime == "\(kind)/mp4" else { throw YlDashBounds.unsupported }
        let location = try base(representation, base(adaptation, periodBase))
        let track = try buildTrack(ancestors, attributes, kind, duration, location)
        if kind == "video" { guard video == nil else { throw YlDashBounds.unsupported }; video = track }
        else { guard audio == nil else { throw YlDashBounds.unsupported }; audio = track }
      }
      guard let video = video else { throw YlDashBounds.unsupported }
      if let previous = result.last {
        guard video.matches(previous.video), (audio == nil) == (previous.audio == nil),
              audio == nil || audio!.matches(previous.audio!) else { throw YlDashBounds.unsupported }
      }
      result.append(YlDashPeriod(video: video, audio: audio))
    }
    guard total == nil || total == end else { throw YlDashBounds.unsupported }
    return (result, end)
  }
  private func buildTrack(_ ancestors: [YlDashNode], _ attrs: [String: String], _ kind: String,
    _ duration: Int64, _ location: (URL, Bool)) throws -> YlDashTrack {
    guard let codec = attrs["codecs"],
      (kind == "video" ? codec.range(of: #"^avc[13]\.[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil : codec == "mp4a.40.2") else { throw YlDashBounds.unsupported }
    let width = try YlDashBounds.number(attrs["width"], default: 0)
    let height = try YlDashBounds.number(attrs["height"], default: 0)
    let rate = try YlDashBounds.number(attrs["audioSamplingRate"], default: 0)
    let bandwidth = try YlDashBounds.number(attrs["bandwidth"])
    guard bandwidth > 0, bandwidth <= 1_000_000_000, (kind == "video" ? width > 0 && height > 0 && width <= 65535 && height <= 65535 : rate > 0 && rate <= 768000) else { throw YlDashBounds.unsupported }
    var channels = ""
    var roles: [String] = []
    for node in ancestors {
      for role in node.nodes("Role") {
        guard role.attributes["schemeIdUri", default: "urn:mpeg:dash:role:2011"] == "urn:mpeg:dash:role:2011",
              let value = role.attributes["value"],
              ["main", "alternate", "supplementary", "commentary", "dub", "caption", "subtitle", "description", "enhanced-audio-intelligibility", "emergency"].contains(value) else { throw YlDashBounds.unsupported }
        roles.append(value)
      }
      if let config = try node.one("AudioChannelConfiguration") {
        guard config.attributes["schemeIdUri"] == "urn:mpeg:dash:23003:3:audio_channel_configuration:2011" else { throw YlDashBounds.unsupported }
        let number = try YlDashBounds.number(config.attributes["value"])
        guard number > 0, number <= 8 else { throw YlDashBounds.unsupported }; channels = String(number)
      }
    }
    var mode: String?; var segmentAttrs: [String: String] = [:]
    var timeline: YlDashNode?; var initialization: YlDashNode?; var urls: [YlDashNode] = []
    for node in ancestors {
      for name in ["SegmentTemplate", "SegmentList"] {
        if let segment = try node.one(name) {
          guard mode == nil || mode == name else { throw YlDashBounds.unsupported }; mode = name
          segmentAttrs.merge(segment.attributes) { _, new in new }
          if let value = try segment.one("SegmentTimeline") { timeline = value }
          if let value = try segment.one("Initialization") { initialization = value }
          if !segment.nodes("SegmentURL").isEmpty { urls = segment.nodes("SegmentURL") }
        }
      }
    }
    guard let mode = mode else { throw YlDashBounds.unsupported }
    let scale = try YlDashBounds.number(segmentAttrs["timescale"], default: 1)
    guard scale > 0, try YlDashBounds.number(segmentAttrs["presentationTimeOffset"], default: 0) == 0 else { throw YlDashBounds.unsupported }
    let product = try YlDashBounds.multiply(duration, scale)
    guard product % 1_000_000 == 0 else { throw YlDashBounds.unsupported }
    let total = product / 1_000_000
    var samples: [(Int64, Int64)] = []
    func append(_ start: Int64, _ d: Int64, _ count: Int64) throws {
      guard d > 0, count > 0, count <= Int64(YlDashBounds.maxSegments - segmentCount),
        try YlDashBounds.add(start, YlDashBounds.multiply(d, count)) <= total else { throw YlDashBounds.unsupported }
      segmentCount += Int(count)
      for i in 0..<count { samples.append((try YlDashBounds.add(start, YlDashBounds.multiply(i, d)), d)) }
    }
    if let timeline = timeline {
      let entries = timeline.nodes("S")
      guard entries.count == timeline.children.count, !entries.isEmpty else { throw YlDashBounds.unsupported }
      var cursor: Int64 = 0
      for (index, entry) in entries.enumerated() {
        let t = try YlDashBounds.number(entry.attributes["t"], default: cursor)
        let d = try YlDashBounds.number(entry.attributes["d"])
        guard t == cursor, d > 0 else { throw YlDashBounds.unsupported }
        let r = entry.attributes["r", default: "0"]
        let count: Int64
        if r == "-1" {
          let boundary = try index + 1 < entries.count ? YlDashBounds.number(entries[index + 1].attributes["t"]) : total
          guard boundary > t, (boundary - t) % d == 0 else { throw YlDashBounds.unsupported }
          count = (boundary - t) / d
        } else { count = try YlDashBounds.add(YlDashBounds.number(r), 1) }
        try append(t, d, count)
        cursor = try YlDashBounds.add(t, YlDashBounds.multiply(d, count))
      }
      guard cursor == total else { throw YlDashBounds.unsupported }
    } else {
      let d = try YlDashBounds.number(segmentAttrs["duration"])
      guard d > 0, total % d == 0 else { throw YlDashBounds.unsupported }
      try append(0, d, total / d)
    }
    let startNumber = try YlDashBounds.number(segmentAttrs["startNumber"], default: 1)
    let id = attrs["id", default: ""]
    let initResource: YlDashResource
    var segments: [YlDashSegment] = []
    if mode == "SegmentTemplate" {
      guard let initTemplate = segmentAttrs["initialization"], let media = segmentAttrs["media"] else { throw YlDashBounds.unsupported }
      let initName = try template(initTemplate, id: id, bandwidth: bandwidth, number: nil, time: nil)
      initResource = YlDashResource(url: try record(initName, base: location.0, inherited: location.1), range: nil)
      for (i, sample) in samples.enumerated() {
        let name = try template(media, id: id, bandwidth: bandwidth, number: YlDashBounds.add(startNumber, Int64(i)), time: sample.0)
        segments.append(YlDashSegment(resource: YlDashResource(url: try record(name, base: location.0, inherited: location.1), range: nil), ticks: sample.1, scale: scale))
      }
    } else {
      guard let initialization = initialization, urls.count == samples.count else { throw YlDashBounds.unsupported }
      initResource = try resource(initialization.attributes["sourceURL"], initialization.attributes["range"], location)
      for (i, node) in urls.enumerated() {
        guard node.attributes["index"] == nil, node.attributes["indexRange"] == nil else { throw YlDashBounds.unsupported }
        segments.append(YlDashSegment(resource: try resource(node.attributes["media"], node.attributes["mediaRange"], location), ticks: samples[i].1, scale: scale))
      }
    }
    return YlDashTrack(codec: codec, width: width, height: height, samplingRate: rate,
      channels: channels, roles: roles.sorted(), bandwidth: bandwidth, initialization: initResource, segments: segments)
  }
  private func resource(_ name: String?, _ range: String?, _ location: (URL, Bool)) throws -> YlDashResource {
    guard let name = name else { throw YlDashBounds.unsupported }
    var normalized: String?
    if let range = range {
      let parts = range.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw YlDashBounds.unsupported }
      let start = try YlDashBounds.number(String(parts[0])); let end = try YlDashBounds.number(String(parts[1]))
      guard end >= start else { throw YlDashBounds.unsupported }
      normalized = "\(try YlDashBounds.add(end - start, 1))@\(start)"
    }
    return YlDashResource(url: try record(name, base: location.0, inherited: location.1), range: normalized)
  }
  private func template(_ value: String, id: String, bandwidth: Int64, number: Int64?, time: Int64?) throws -> String {
    guard value.utf16.count <= YlDashBounds.maxURI else { throw YlDashBounds.unsupported }
    let parts = value.components(separatedBy: "$")
    guard parts.count % 2 == 1 else { throw YlDashBounds.unsupported }
    var output = ""
    for (index, part) in parts.enumerated() {
      let addition: String
      if index % 2 == 0 { addition = part }
      else if part.isEmpty { addition = "$" }
      else if part == "RepresentationID" { guard !id.isEmpty else { throw YlDashBounds.unsupported }; addition = id }
      else {
        let fields = part.components(separatedBy: "%")
        guard fields.count <= 2 else { throw YlDashBounds.unsupported }
        let n: Int64?
        switch fields[0] { case "Bandwidth": n = bandwidth; case "Number": n = number; case "Time": n = time; default: n = nil }
        guard let n = n else { throw YlDashBounds.unsupported }
        var width = 0
        if fields.count == 2 {
          let format = fields[1]
          guard format.hasPrefix("0"), format.hasSuffix("d"), format.count <= 4 else { throw YlDashBounds.unsupported }
          let parsed = try YlDashBounds.number(String(format.dropFirst().dropLast()))
          guard parsed > 0, parsed <= 20 else { throw YlDashBounds.unsupported }; width = Int(parsed)
        }
        let digits = String(n); addition = String(repeating: "0", count: max(0, width - digits.count)) + digits
      }
      guard addition.utf16.count <= YlDashBounds.maxURI - output.utf16.count else { throw YlDashBounds.unsupported }
      output += addition
    }
    return output
  }
}
