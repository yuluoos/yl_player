from pathlib import Path
import sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();s=s[:s.index('private final class DashHeldBodyServer {')]+'''private final class DashHeldBodyServer {
  private let listener: NWListener
  private let lock = NSLock()
  private var connections: [ObjectIdentifier:NWConnection] = [:]
  private var heldConnections = Set<ObjectIdentifier>()
  private var stopped = false, closed = 0, held = 0
  private let manifest: Data, body: Data, redirect: URL, normalBodies: [String:Data]
  var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held }
  var peerClosed: Int { lock.lock(); defer { lock.unlock() }; return closed }
  func url(_ path:String) -> URL { URL(string:"http://127.0.0.1:\\(listener.port!.rawValue)\\(path)")! }
  init(manifest:Data,body:Data,redirect:URL,normalBodies:[String:Data] = [:]) throws {
    self.manifest = manifest; self.body = body; self.redirect = redirect; self.normalBodies = normalBodies
    listener = try NWListener(using:.tcp,on:.any)
    let ready = DispatchSemaphore(value:0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.lock.lock()
      guard !self.stopped else { self.lock.unlock(); connection.cancel(); return }
      self.connections[ObjectIdentifier(connection)] = connection
      connection.start(queue:DispatchQueue.global())
      self.lock.unlock()
      self.receiveHeader(connection,buffer:Data())
    }
    listener.start(queue:DispatchQueue(label:"yl.test.held-body"))
    guard ready.wait(timeout:.now()+3) == .success else { listener.cancel(); throw NSError(domain:"HeldBody",code:1) }
  }
  private func finish(_ connection:NWConnection,peer:Bool = false) {
    lock.lock(); let id = ObjectIdentifier(connection)
    connections.removeValue(forKey:id)
    if heldConnections.remove(id) != nil && peer { closed += 1 }
    lock.unlock(); connection.cancel()
  }
  private func receiveHeader(_ connection:NWConnection,buffer:Data) {
    connection.receive(minimumIncompleteLength:1,maximumLength:4096) { [weak self] bytes,_,complete,error in
      guard let self else { connection.cancel(); return }
      var data = buffer; if let bytes { data.append(bytes) }
      guard data.count<=16384 else { self.finish(connection); return }
      if let end = data.range(of:Data([13,10,13,10])) {
        self.respond(connection,header:String(decoding:data[..<end.upperBound],as:UTF8.self))
      } else if complete || error != nil { self.finish(connection) }
      else { self.receiveHeader(connection,buffer:data) }
    }
  }
  private func observeEOF(_ connection:NWConnection) {
    connection.receive(minimumIncompleteLength:1,maximumLength:1024) { [weak self] _,_,complete,error in
      guard let self else { connection.cancel(); return }
      if complete || error != nil { self.finish(connection,peer:true) }
      else { self.observeEOF(connection) }
    }
  }
  private func respond(_ connection:NWConnection,header:String) {
    let lines = header.components(separatedBy:"\\r\\n")
    let path = lines[0].split(separator:" ").dropFirst().first.map(String.init) ?? ""
    var headers: [String:String] = [:]
    for line in lines.dropFirst() {
      if let colon = line.firstIndex(of:":") { headers[String(line[..<colon]).lowercased()] = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces) }
    }
    if path == "/revoke" {
      connection.send(content:Data("HTTP/1.1 302 Found\\r\\nContent-Length: 0\\r\\nLocation: \\(redirect.absoluteString)\\r\\nConnection: close\\r\\n\\r\\n".utf8),completion:.contentProcessed { [weak self] _ in self?.finish(connection) })
      return
    }
    let payload = path == "/movie.mpd" ? manifest : (normalBodies[path] ?? body)
    let hold = path != "/movie.mpd" && (normalBodies.isEmpty || headers["x-fixture-hold"] == "1")
    lock.lock()
    guard !stopped, connections[ObjectIdentifier(connection)] != nil else { lock.unlock(); connection.cancel(); return }
    if hold { held += 1; heldConnections.insert(ObjectIdentifier(connection)) }
    lock.unlock()
    let response = "HTTP/1.1 200 OK\\r\\nContent-Length: \\(payload.count)\\r\\nConnection: close\\r\\n\\r\\n"
    if hold {
      connection.send(content:Data(response.utf8)+payload.prefix(64),completion:.contentProcessed { _ in })
      observeEOF(connection)
    } else {
      connection.send(content:Data(response.utf8)+payload,completion:.contentProcessed { [weak self] _ in self?.finish(connection) })
    }
  }
  func close() {
    lock.lock(); stopped = true; let pending = Array(connections.values); connections.removeAll(); lock.unlock()
    listener.cancel(); pending.forEach { $0.cancel() }
  }
  deinit { close() }
}
'''
a='''    let server = try DashHeldBodyServer(manifest:mpd,body:Data(contentsOf:media),redirect:other.url("/revoked"))
    defer { server.close(); other.close() }
    let context = YlHlsCredentialContext()
    let candidate = try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL:server.url("/movie.mpd"),headers:[:],credentials:["Authorization":"fixture"],credentialContext:context)
    defer { candidate.discard() }
    let accepted = try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL:server.url("/movie.mpd"),headers:[:],credentials:["Authorization":"fixture"],credentialContext:context)
    let active = try accepted.takeLoader(); defer { active.cancelAll() }'''
b='''    let segmentBytes = try Data(contentsOf:media.deletingLastPathComponent().appendingPathComponent("chunk-0-00001.m4s"))
    let initBytes = try Data(contentsOf:media)
    let server = try DashHeldBodyServer(manifest:mpd,body:initBytes,redirect:other.url("/revoked"),
      normalBodies:["/init.mp4":initBytes,"/seg-1.m4s":segmentBytes,"/seg-2.m4s":segmentBytes])
    defer { server.close(); other.close() }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    var request = AppleHostFixture.request("committed",url:server.url("/movie.mpd").absoluteString,format:.dash)
    request.source.request = .init(credentials:["Authorization":"fixture"])
    let accepted = try await fixture.host.load(request:request)
    let acceptedItem = try XCTUnwrap(fixture.av.currentItem)
    let active = try XCTUnwrap((acceptedItem.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    let context = active.credentialContext
    // Fixture-only header stalls candidate traffic, never the committed item's traffic.
    let candidate = try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL:server.url("/movie.mpd"),headers:["X-Fixture-Hold":"1"],credentials:["Authorization":"fixture"],credentialContext:context)
    defer { candidate.discard() }'''
assert a in s;s=s.replace(a,b,1)
a='''    XCTAssertNil(read(active,try active.encodedAssetURL()).error,"Cancelling candidate must not cancel committed loader")
    XCTAssertEqual(active.diagnosticProxySnapshot["cancelled"],0)'''
b='''    XCTAssertEqual(fixture.host.sessionId,accepted.sessionId); XCTAssertTrue(fixture.av.currentItem === acceptedItem)
    let root = read(active,try active.encodedAssetURL()); XCTAssertNil(root.error)
    let video = read(active,try child(root.received))
    let segmentURL = try XCTUnwrap(String(decoding:video.received,as:UTF8.self).split(separator:"\\n").first { $0.hasPrefix("http:") }.flatMap { URL(string:String($0)) })
    let (continued,response) = try await URLSession.shared.data(from:segmentURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200); XCTAssertEqual(continued,segmentBytes)
    XCTAssertEqual(active.diagnosticProxySnapshot["cancelled"],0)'''
assert a in s;s=s.replace(a,b,1);p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("{'ios': 849, 'macos': 893}","{'ios': 850, 'macos': 894}"))
