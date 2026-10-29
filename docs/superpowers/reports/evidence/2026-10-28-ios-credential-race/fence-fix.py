from pathlib import Path
import sys
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsHeaderPolicy.swift');s=p.read_text().replace('''  func withUnchangedRevision(_ expected: UInt64, _ commit: () throws -> Void) rethrows -> Bool {
    guard revision == expected else { return false }''','''  /// Serializes a short synchronous commit with provenance changes. The body
  /// must not reenter this context or perform/wait for network preparation.
  func withUnchangedRevision(_ expected: UInt64, _ commit: () throws -> Void) rethrows -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard UInt64(strippedResources.count) == expected else { return false }''',1);p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();a='''          } else if automaticPolicy.authorizes(ticket, automaticSample()) && player.currentItem === item {
            warmedItem = freshPreparedItem
            try XCTUnwrap(backend).replaceActiveDash(source: source, prepared: replacement)
            if let freshPreparedItem { event["freshPreparedItemInstalled"] = player.currentItem === freshPreparedItem }
            event["outcome"] = "installed"; event["itemChanged"] = player.currentItem !== item
''';b='''          } else if automaticPolicy.authorizes(ticket, automaticSample()) && player.currentItem === item && currentCredentialContext() === credentials {
            // This owned backend has no reentrant credential callbacks. Both
            // DASH loaders have completed preflight; no network wait is allowed
            // in the synchronous replacement. Background strip linearizes
            // either before this fence (reject) or after installation.
            let committed = try credentials.withUnchangedRevision(ticket.credentialRevision) {
              warmedItem = freshPreparedItem
              try XCTUnwrap(backend).replaceActiveDash(source: source, prepared: replacement)
            }
            event["credentialCommitAccepted"] = committed
            if committed {
              if let freshPreparedItem { event["freshPreparedItemInstalled"] = player.currentItem === freshPreparedItem }
              event["outcome"] = "installed"; event["itemChanged"] = player.currentItem !== item
            } else {
              replacement.asset.cancelLoading(); replacement.discard(); event["outcome"] = "cancelled"
            }
''';assert a in s;s=s.replace(a,b,1)
s=s.replace('''    defer { candidate.discard() }
    func segment''','''    defer { candidate.discard() }
    let cancelledCandidate = try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL:server.url("/movie.mpd"),
      headers:["X-Client":"ordinary"],credentials:["X-Session":"fixture"],credentialContext:context)
    defer { cancelledCandidate.discard() }
    func segment''',1).replace('},cancelPending:{ cleanups += 1 })','},cancelPending:{ cleanups += 1; cancelledCandidate.discard() })',1).replace('    XCTAssertEqual(policy.attempts,1,"A credential change never refunds the source budget")','    XCTAssertEqual(policy.attempts,1,"A credential change never refunds the source budget")\n    XCTAssertThrowsError(try cancelledCandidate.takeLoader(),"Revocation must consume and cancel the candidate loader")\n    XCTAssertEqual(cancelledCandidate.loader.diagnosticProxySnapshot["cancelled"],1)',1)
marker='  func testCredentialRevisionIsConcurrentIdempotentAndLoadScoped() {'
s=s.replace(marker,'''  @MainActor func testCredentialFenceCoversActualDashBackendItemInstallation() throws {
    let context = YlHlsCredentialContext(), data = mpd
    let original = try prepare(DashLoaderProtocol.configuration { $0.respond(data) },context:context)
    let candidate = try prepare(DashLoaderProtocol.configuration { $0.respond(data) },context:context)
    defer { candidate.discard() }
    let player = AVPlayer()
    let attempted = DispatchSemaphore(value:0), finished = DispatchSemaphore(value:0)
    let done = expectation(description:"strip completes after backend item commit")
    var replacing = false
    let backend = YlAvPlayerBackend(playerId:995,
      services:.init(platform:.current,textureOutput:AppleTestTexture(),makeDisplayDriver:{ _ in AppleTestDisplay() }),
      configuration:.init(map:["audioPolicy":"appManaged"]),player:player,
      makePlayerItem:{ asset in
        if replacing {
          DispatchQueue.global().async {
            attempted.signal(); context.strip("changed-at-install"); finished.signal(); done.fulfill()
          }
          XCTAssertEqual(attempted.wait(timeout:.now()+1),.success)
          XCTAssertEqual(finished.wait(timeout:.now()+0.05),.timedOut)
        }
        return AVPlayerItem(asset:asset)
      },emit:{ _ in })
    defer { backend.dispose() }
    let source = YlAppleSourceDescriptor(uri:origin.absoluteString,kind:.network,formatHint:.dash)
    try backend.stagePreparedHls(source:source,prepared:original,resume:false)
    try backend.activate()
    let oldItem = try XCTUnwrap(player.currentItem)
    replacing = true
    XCTAssertTrue(try context.withUnchangedRevision(0) { try backend.replaceActiveDash(source:source,prepared:candidate) })
    XCTAssertTrue(player.currentItem !== oldItem)
    wait(for:[done],timeout:2)
    XCTAssertEqual(context.revision,1)
  }

'''+marker,1)
p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("{'ios': 845, 'macos': 889}","{'ios': 847, 'macos': 891}"))
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text().replace("        for event_key,key in [('ticketIntentRevision','intentRevision'),('ticketCredentialRevision','credentialRevision')]:","        if e.get('outcome') == 'installed': require(e.get('credentialCommitAccepted') is True)\n        for event_key,key in [('ticketIntentRevision','intentRevision'),('ticketCredentialRevision','credentialRevision')]:",1);p.write_text(s)
p=Path('tool/playback_network/test_abr_policy.py');s=p.read_text().replace("event=dict(attempt=1,elapsed=17.51,ticketIntentRevision=2,ticketCredentialRevision=3)","event=dict(attempt=1,elapsed=17.51,ticketIntentRevision=2,ticketCredentialRevision=3,outcome='installed',credentialCommitAccepted=True)").replace("'wrong-time','bool-version']:","'wrong-time','bool-version','missing-fence']:").replace("            else:e['ticketCredentialRevision']=True","            elif mutation=='missing-fence':e.pop('credentialCommitAccepted')\n            else:e['ticketCredentialRevision']=True");p.write_text(s)
p=Path('tool/playback_network/README.md');p.write_text(p.read_text()+'''\nThe final diagnostic installation is synchronous under the same context lock as\n`strip`, after both DASH loaders finish preflight. It never waits for network or\nreenters the context; background changes order before the fence (reject) or after\nactual item installation. V2 installed events require `credentialCommitAccepted`.\nThis fence is exercised through actual backend item replacement, independently\nof the local readiness/redirect test; it does not enable production recovery.\n''')
