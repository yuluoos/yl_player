import Foundation

@main struct LiveStoreTests {
  static var checks = 0
  static func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fatalError(message) }
  }
  static func contents(_ store: YlAirPlayLiveStore, _ name: String) throws -> String? {
    guard let resource = try store.resolve(name) else { return nil }
    defer { try? resource.close() }
    return String(data: try resource.file.readToEnd() ?? Data(), encoding: .utf8)
  }
  static func request(_ url: URL, method: String = "GET", range: String? = nil) throws -> (Int, Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 5
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    let done = DispatchSemaphore(value: 0)
    var outcome: (Data?, URLResponse?, Error?)?
    URLSession.shared.dataTask(with: request) { data, response, error in
      outcome = (data, response, error)
      done.signal()
    }.resume()
    guard done.wait(timeout: .now() + 10) == .success, let outcome else { fatalError("HTTP timeout") }
    if let error = outcome.2 { throw error }
    let response = outcome.1 as! HTTPURLResponse
    return (response.statusCode, outcome.0 ?? Data(), response)
  }
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var now = 100.0
    let store = try YlAirPlayLiveStore(directory: root, now: { now })
    let period = try store.beginPeriod(initialization: Data("init-0".utf8))
    for _ in 0..<2 { try store.append(data: Data("segment".utf8), duration: 6, period: period) }
    expect(!store.isReady, "must wait for three target durations")
    expect(try contents(store, "index.m3u8") == nil, "no undersized playlist")
    try store.append(data: Data("segment".utf8), duration: 6, period: period)
    expect(store.isReady, "initial playlist available before EOF")
    let server = try YlAirPlayHTTPServer(host: "127.0.0.1", resolver: store.resolve)
    defer { server.stop() }
    let initialHTTP = try request(server.url)
    expect(initialHTTP.0 == 200 && initialHTTP.2.value(forHTTPHeaderField: "Cache-Control") == "no-store", "live playlist cannot be cached")
    let segmentURL = server.url.deletingLastPathComponent().appendingPathComponent("segment-0.m4s")
    let ranged = try request(segmentURL, range: "bytes=1-3")
    expect(ranged.0 == 206 && String(data: ranged.1, encoding: .utf8) == "egm", "dynamic resource range")
    expect(try request(segmentURL, method: "HEAD").1.isEmpty, "HEAD has no body")
    expect(try request(segmentURL, range: "bytes=999-").0 == 416, "invalid range rejected")
    expect(try request(server.url.deletingLastPathComponent().appendingPathComponent("unknown.mp4")).0 == 404, "dynamic allowlist")
    let first = try contents(store, "index.m3u8")!
    expect(first.contains("#EXT-X-TARGETDURATION:6\n"), "constant target")
    expect(!first.contains("ENDLIST") && !first.contains("PLAYLIST-TYPE"), "running live playlist")
    expect(first.contains("#EXT-X-MEDIA-SEQUENCE:0\n"), "initial sequence")
    let heldPlaylist = try store.resolve("index.m3u8")!
    let heldMedia = try store.resolve("segment-0.m4s")!
    for _ in 0..<3 { try store.append(data: Data("segment".utf8), duration: 6, period: period) }
    let rolled = try contents(store, "index.m3u8")!
    expect(rolled.contains("#EXT-X-MEDIA-SEQUENCE:1\n"), "sliding sequence")
    expect(String(data: try request(server.url).1, encoding: .utf8) == rolled, "HTTP reflects newly published index")
    expect(try contents(store, "segment-0.m4s") != nil, "removed media remains fetchable")
    expect(String(data: try heldPlaylist.file.readToEnd()!, encoding: .utf8) == first, "atomic playlist preserves open old snapshot")
    try heldPlaylist.close()
    now = 135.9
    expect(try contents(store, "segment-0.m4s") != nil, "retain for previous max playlist plus segment duration")
    now = 136.1
    expect(try contents(store, "segment-0.m4s") == nil, "expired media cannot acquire new readers")
    expect(String(data: try heldMedia.file.readToEnd()!, encoding: .utf8) == "segment", "open leases remain readable after expiry")
    try heldMedia.close()
    let next = try store.beginPeriod(initialization: Data("init-1".utf8))
    try store.append(data: Data("new".utf8), duration: 6, period: next)
    let transition = try contents(store, "index.m3u8")!
    expect(transition.contains("#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init-1.mp4\""), "new map at discontinuity")
    for _ in 0..<5 { try store.append(data: Data("new".utf8), duration: 6, period: next) }
    let advanced = try contents(store, "index.m3u8")!
    expect(advanced.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1\n"), "discontinuity count advances when boundary leaves playlist")
    expect(!advanced.contains("#EXT-X-DISCONTINUITY\n"), "no synthetic boundary at first segment")
    expect(try contents(store, "../index.m3u8") == nil, "resolver allowlist")
    expect(try contents(store, "init-0.mp4") == "init-0", "old map retained with old media")
    now += 40
    expect(try contents(store, "init-0.mp4") == nil, "old map expires after all its media")
    try store.finish()
    expect(try contents(store, "index.m3u8")!.contains("#EXT-X-ENDLIST"), "finish marks terminal")

    let vod = try YlAirPlayHTTPServer(directory: root, files: ["index.m3u8", "segment-6.m4s"], host: "127.0.0.1")
    defer { vod.stop() }
    expect(try request(vod.url).0 == 200, "legacy VOD initializer")
    expect(try request(vod.url.deletingLastPathComponent().appendingPathComponent("init-1.mp4")).0 == 404, "VOD allowlist still enforced")
    expect(try request(vod.url, method: "POST").0 == 405, "HTTP methods restricted")
    let foreignCapability = URL(string: "http://127.0.0.1:\(vod.url.port!)/wrong/index.m3u8")!
    expect(try request(foreignCapability).0 == 404, "capability boundary")
    let encoded = URL(string: vod.url.deletingLastPathComponent().absoluteString + "/%69ndex.m3u8")!
    expect(try request(encoded).0 == 404, "encoded paths rejected")

    let rounded = try YlAirPlayLiveStore(directory: root.appendingPathComponent("rounded"))
    let roundedPeriod = try rounded.beginPeriod(initialization: Data([1]))
    for _ in 0..<3 { try rounded.append(data: Data([1]), duration: 6.49, period: roundedPeriod) }
    expect(rounded.isReady, "HLS nearest integer target duration tolerance")

    let invalid = try YlAirPlayLiveStore(directory: root.appendingPathComponent("invalid"))
    let invalidPeriod = try invalid.beginPeriod(initialization: Data([1]))
    do { try invalid.append(data: Data([1]), duration: 6.5, period: invalidPeriod); fatalError("accepted segment beyond target") }
    catch let error as NativePlayerError { expect(error.code == "unsupported_timeline", "duration bound error") }
    do { try invalid.checkError(); fatalError("error not latched") } catch {}

    let bounded = try YlAirPlayLiveStore(directory: root.appendingPathComponent("bounded"))
    let boundedPeriod = try bounded.beginPeriod(initialization: Data([1]))
    for _ in 0..<12 { try bounded.append(data: Data(repeating: 1, count: 10 * 1024 * 1024), duration: 6, period: boundedPeriod) }
    do { try bounded.append(data: Data(repeating: 1, count: 10 * 1024 * 1024), duration: 6, period: boundedPeriod); fatalError("exceeded disk bound") }
    catch let error as NativePlayerError { expect(error.code == "resource_limit", "disk exhaustion is explicit") }
    expect(try contents(bounded, "segment-0.m4s") != nil, "resource exhaustion cannot evict unexpired segment")
    var leasedNow = 100.0
    let leasedDirectory = root.appendingPathComponent("leased")
    let leased = try YlAirPlayLiveStore(directory: leasedDirectory, now: { leasedNow })
    let leasedPeriod = try leased.beginPeriod(initialization: Data([1]))
    let tenMiB = Data(repeating: 1, count: 10 * 1024 * 1024)
    for _ in 0..<12 { try leased.append(data: tenMiB, duration: 6, period: leasedPeriod) }
    let reader = try leased.resolve("segment-0.m4s")!
    leasedNow = 137
    for _ in 0..<6 { try leased.append(data: tenMiB, duration: 6, period: leasedPeriod) }
    do { try leased.append(data: tenMiB, duration: 6, period: leasedPeriod); fatalError("held expired file escaped disk accounting") }
    catch let error as NativePlayerError { expect(error.code == "resource_limit", "held expired media stays in disk accounting") }
    expect(FileManager.default.fileExists(atPath: leasedDirectory.appendingPathComponent("segment-0.m4s").path), "leased media remains named until close")
    try reader.close()
    try reader.close()
    expect(!FileManager.default.fileExists(atPath: leasedDirectory.appendingPathComponent("segment-0.m4s").path), "idempotent lease close releases expired media")

    var releaseNow = 100.0
    let releaseDirectory = root.appendingPathComponent("release")
    let releasing = try YlAirPlayLiveStore(directory: releaseDirectory, now: { releaseNow })
    let releasePeriod = try releasing.beginPeriod(initialization: Data([1]))
    for _ in 0..<6 { try releasing.append(data: Data([1]), duration: 6, period: releasePeriod) }
    let firstReader = try releasing.resolve("segment-0.m4s")!
    var finalReader: YlAirPlayHTTPResource? = try releasing.resolve("segment-0.m4s")!
    expect(finalReader?.length == 1, "second lease opens same retained media")
    releaseNow = 137
    try firstReader.close()
    try firstReader.close()
    expect(FileManager.default.fileExists(atPath: releaseDirectory.appendingPathComponent("segment-0.m4s").path), "duplicate close cannot release another reader")
    finalReader = nil
    expect(!FileManager.default.fileExists(atPath: releaseDirectory.appendingPathComponent("segment-0.m4s").path), "last reader deinit retires expired media")

    let snapshotStore = try YlAirPlayLiveStore(directory: root.appendingPathComponent("snapshots"))
    let snapshotPeriod = try snapshotStore.beginPeriod(initialization: Data([1]))
    for _ in 0..<3 { try snapshotStore.append(data: Data([1]), duration: 6, period: snapshotPeriod) }
    let oldSnapshot = try snapshotStore.resolve("index.m3u8")!
    for _ in 0..<121 { try snapshotStore.append(data: Data([1]), duration: 6, period: snapshotPeriod) }
    do { try snapshotStore.append(data: Data([1]), duration: 6, period: snapshotPeriod); fatalError("unlinked playlist snapshot escaped file accounting") }
    catch let error as NativePlayerError { expect(error.code == "resource_limit", "held old playlist counts toward file limit") }
    expect(try oldSnapshot.file.readToEnd()?.isEmpty == false, "old playlist snapshot remains readable at limit")
    try oldSnapshot.close()

    let counted = try YlAirPlayLiveStore(directory: root.appendingPathComponent("counted"))
    let countedPeriod = try counted.beginPeriod(initialization: Data([1]))
    for _ in 0..<125 { try counted.append(data: Data([1]), duration: 6, period: countedPeriod) }
    do { try counted.append(data: Data([1]), duration: 6, period: countedPeriod); fatalError("exceeded file bound") }
    catch let error as NativePlayerError { expect(error.code == "resource_limit", "file count bound") }
    expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("counted").path).count <= 128, "physical file count bounded")

    let short = try YlAirPlayLiveStore(directory: root.appendingPathComponent("short"))
    let shortPeriod = try short.beginPeriod(initialization: Data([1]))
    for _ in 0..<32 { try short.append(data: Data([1]), duration: 0.5, period: shortPeriod) }
    do { try short.append(data: Data([1]), duration: 0.5, period: shortPeriod); fatalError("exceeded active window count") }
    catch let error as NativePlayerError { expect(error.code == "resource_limit", "active count limit preserves minimum duration") }
    print("PASS: \(checks) live store checks")
  }
}
