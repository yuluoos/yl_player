import Foundation
let media = URL(fileURLWithPath: CommandLine.arguments[1])
let origin = URL(string: "https://origin.example/program/manifest.mpd")!
var results: [[String: Any]] = []
func check(_ name: String, _ body: () throws -> Bool) {
  do { results.append(["name": name, "passed": try body()]) }
  catch { results.append(["name": name, "passed": false, "error": String(describing: error)]) }
}
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
func bytes(_ name: String) throws -> Data { try Data(contentsOf: media.appendingPathComponent(name + ".mpd")) }
func text(_ name: String) throws -> String { String(data: try bytes(name), encoding: .utf8)! }
func parse(_ data: Data) throws -> YlDashProgram { try YlDashProgramDocument.parse(data, source: origin, final: origin) }
func t(_ n: Int64, _ d: Int64 = 1) throws -> YlDashProgramTime { try .init(n, d) }
for name in ["independent-pto", "clip-end", "gap", "overlap", "unknown-middle", "multiple-base", "fractional-microsecond"] {
  check("real fixture " + name) {
    let program = try parse(bytes(name))
    let duration: YlDashProgramTime
    switch name { case "clip-end": duration = try t(7, 2); case "gap": duration = try t(9); case "overlap": duration = try t(7); case "unknown-middle": duration = try t(8); case "fractional-microsecond": duration = try t(1, 3); default: duration = try t(4) }
    return program.timeline.duration == duration && !program.periods[0].tracks.isEmpty
  }
}
check("independent offsets stay on each track") {
  let program = try parse(bytes("independent-pto")), tracks = program.periods[0].tracks
  return try tracks.first { $0.kind == .video }!.offset == t(10) && tracks.first { $0.kind == .audio }!.offset == t(20)
}
check("clip does not rewrite source segment duration") {
  let program = try parse(bytes("clip-end")), track = program.periods[0].tracks.first { $0.kind == .video }!
  return try track.segments.last!.start.adding(track.segments.last!.duration) == t(4) && program.timeline.end(of: 0) == t(7, 2)
}
check("multiple BaseURL preserves declaration order") {
  let track = try parse(bytes("multiple-base")).periods[0].tracks[0]
  return track.initialization!.candidates.map { $0.url.path } == ["/program/period0/init-0.m4s", "/program/period1/init-0.m4s"]
}
check("cross origin then same origin stays stripped") {
  let xml = try text("multiple-base").replacingOccurrences(of: "<BaseURL>period0/</BaseURL><BaseURL>period1/</BaseURL>", with: "<BaseURL>https://other.example/</BaseURL>")
    .replacingOccurrences(of: "<Representation id=\"0\"", with: "<Representation id=\"0\"")
    .replacingOccurrences(of: "<SegmentTemplate timescale=\"12288\"", with: "<BaseURL>https://origin.example/back/</BaseURL><SegmentTemplate timescale=\"12288\"")
  let track = try parse(Data(xml.utf8)).periods[0].tracks[0]
  return track.initialization!.candidates[0].credentialsStripped && track.initialization!.candidates[0].url.host == origin.host
}
check("old HLS admission remains strict") {
  for name in ["independent-pto", "clip-end", "gap", "overlap", "unknown-middle", "multiple-base", "fractional-microsecond"] {
    if !rejects({ _ = try YlDashDocument(source: origin).parse(bytes(name), final: origin, credentialsStripped: false) }) { return false }
  }
  return true
}
check("fractional MPD duration keeps exact digits") {
  let xml = try text("fractional-microsecond").replacingOccurrences(of: "<Period>", with: "<Period duration=\"PT0.123456789S\">")
  return try parse(Data(xml.utf8)).timeline.duration == t(123456789, 1000000000)
}
check("unbounded unknown middle is rejected") {
  let xml = try text("unknown-middle").replacingOccurrences(of: "<S t=\"36864\" d=\"12288\"/>", with: "<S t=\"36864\" d=\"12288\" r=\"-1\"/>")
  return rejects { _ = try parse(Data(xml.utf8)) }
}
check("template paths expand exact integer tick values") {
  let xml = try text("independent-pto").replacingOccurrences(of: "chunk-0-$Number%05d$.m4s", with: "chunk-$RepresentationID$-$Time$.m4s")
  return try parse(Data(xml.utf8)).periods[0].tracks[0].segments[0].resource.candidates[0].url.path.hasSuffix("chunk-0-122880.m4s")
}
check("added audio does not invalidate programme model") {
  let original = try text("manifest")
  let start = original.range(of: "<AdaptationSet contentType=\"audio\"")!, end = original.range(of: "</AdaptationSet>", range: start.lowerBound..<original.endIndex)!
  let audio = String(original[start.lowerBound..<end.upperBound]).replacingOccurrences(of: "<AdaptationSet ", with: "<AdaptationSet id=\"commentary\" ")
  let xml = original.replacingOccurrences(of: "</MPD>", with: "</MPD>")
  let insertion = xml.range(of: "</Period>", options: .backwards)!
  let modified = String(xml[..<insertion.lowerBound]) + audio + String(xml[insertion.lowerBound...])
  let program = try parse(Data(modified.utf8))
  return program.periods[0].tracks.filter { $0.kind == .audio }.count == 1 && program.periods[1].tracks.filter { $0.kind == .audio }.count == 2
}
check("XML entities and protected MPD rejected") {
  rejects { _ = try parse(Data("<!DOCTYPE MPD [<!ENTITY e 'x'>]><MPD/>".utf8)) }
    && rejects { _ = try parse(Data("<MPD><Period><ContentProtection/></Period></MPD>".utf8)) }
}
check("finite SegmentList retains byte ranges") {
  let xml = "<MPD mediaPresentationDuration=\"PT2S\"><Period><AdaptationSet mimeType=\"video/mp4\"><Representation id=\"v\" codecs=\"avc1.42c01e\" width=\"320\" height=\"180\" bandwidth=\"300000\"><BaseURL>single.mp4</BaseURL><SegmentList duration=\"1\"><Initialization range=\"0-99\"/><SegmentURL mediaRange=\"100-199\"/><SegmentURL mediaRange=\"200-399\"/></SegmentList></Representation></AdaptationSet></Period></MPD>"
  let track = try parse(Data(xml.utf8)).periods[0].tracks[0]
  return track.initialization!.range == .init(start: 0, length: 100) && track.segments[1].resource.range == .init(start: 200, length: 200)
}
check("duplicate audio identity rejects") {
  let xml = try text("independent-pto")
  let start = xml.range(of: "<AdaptationSet contentType=\"audio\"")!, end = xml.range(of: "</AdaptationSet>", range: start.lowerBound..<xml.endIndex)!
  let audio = String(xml[start.lowerBound..<end.upperBound])
  return rejects { _ = try parse(Data(xml.replacingOccurrences(of: "</Period>", with: audio + "</Period>").utf8)) }
}
check("explicit metadata descriptors survive admission") {
  let xml = try text("fractional-microsecond").replacingOccurrences(of: "<Representation id=\"0\"", with: "<Representation id=\"0\" colourPrimaries=\"9\" transferCharacteristics=\"16\"")
    .replacingOccurrences(of: "<SegmentTemplate", with: "<SupplementalProperty schemeIdUri=\"urn:test:range\" value=\"hdr\"/><SegmentTemplate")
  let track = try parse(Data(xml.utf8)).periods[0].tracks[0]
  return track.attributes["colourPrimaries"] == "9" && track.descriptors.contains { $0["schemeIdUri"] == "urn:test:range" && $0["value"] == "hdr" }
}
check("role delimiter cannot merge two semantic sets") {
  let xml = try text("fractional-microsecond").replacingOccurrences(of: "<Representation", with: "<Role value=\"main,commentary\"/><Representation")
  return rejects { _ = try parse(Data(xml.utf8)) }
}
check("BaseURL combination budget rejects before expansion") {
  let bases = String(repeating: "<BaseURL>x/</BaseURL>", count: 17)
  let xml = try text("fractional-microsecond").replacingOccurrences(of: "<BaseURL>fractional/</BaseURL>", with: bases)
  return rejects { _ = try parse(Data(xml.utf8)) }
}
check("segment expansion budget rejects") {
  let xml = try text("fractional-microsecond").replacingOccurrences(of: "<S t=\"0\" d=\"4096\"/>", with: "<S t=\"0\" d=\"4096\" r=\"100000\"/>")
  return rejects { _ = try parse(Data(xml.utf8)) }
}
check("all original tracks checked before any caps") {
  let xml = try text("fractional-microsecond").replacingOccurrences(of: "</AdaptationSet>", with: "<Representation id=\"poison\" bandwidth=\"9999999999\" codecs=\"avc1.42c01e\" width=\"99999\" height=\"99999\"/></AdaptationSet>")
  return rejects { _ = try parse(Data(xml.utf8)) }
}
check("index requests include candidates and credential lineage") {
  let xml = "<MPD><Period><BaseURL>https://other.example/file.mp4</BaseURL><AdaptationSet><Representation><SegmentBase indexRange=\"100-199\"><Initialization range=\"0-99\"/></SegmentBase></Representation></AdaptationSet></Period></MPD>"
  let requests = try YlDashProgramDocument.indexRequests(Data(xml.utf8), source: origin, final: origin)
  return requests.count == 1 && requests[0].credentialsStripped && requests[0].start == 100 && requests[0].length == 100
}
check("RepresentationID never inherits AdaptationSet id") {
  let xml = try text("independent-pto").replacingOccurrences(of: "<AdaptationSet contentType=\"video\"", with: "<AdaptationSet id=\"parent\" contentType=\"video\"").replacingOccurrences(of: "<Representation id=\"0\"", with: "<Representation").replacingOccurrences(of: "chunk-0-$Number%05d$.m4s", with: "chunk-$RepresentationID$-$Number$.m4s")
  return rejects { _ = try parse(Data(xml.utf8)) }
}
check("sidx alternatives are one logical resource") {
  let xml = Data("<MPD mediaPresentationDuration=\"PT4S\"><Period><AdaptationSet mimeType=\"video/mp4\"><Representation id=\"v\"><BaseURL>https://one.example/v.mp4</BaseURL><BaseURL>https://two.example/v.mp4</BaseURL><SegmentBase indexRange=\"826-905\"><Initialization range=\"0-825\"/></SegmentBase></Representation></AdaptationSet></Period></MPD>".utf8)
  let resources = try YlDashProgramDocument.indexResources(xml, source: origin, final: origin)
  return resources.count == 1 && resources[0].candidates.count == 2 && resources[0].range == .init(start: 826, length: 80)
}
print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), encoding: .utf8)!)
