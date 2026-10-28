from pathlib import Path
import sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text()
s=s.replace('let intentRevision: UInt64 }','let intentRevision: UInt64; let credentialRevision: UInt64 }',1).replace('  private var intentRevision: UInt64?','  private var intentRevision: UInt64?\n  private var credentialRevision: UInt64?',1).replace('"intentRevision": s.intentRevision, "allowed":','"intentRevision": s.intentRevision, "credentialRevision": s.credentialRevision, "allowed":',1).replace('    guard eligible(s), last.map', '    if credentialRevision != s.credentialRevision { credentialRevision = s.credentialRevision; invalidateIntent() }\n    guard eligible(s), last.map',1).replace('intentRevision: s.intentRevision)\n    return nil','intentRevision: s.intentRevision, credentialRevision: s.credentialRevision)\n    return nil',1).replace('s.intentRevision == ticket.intentRevision &&','s.intentRevision == ticket.intentRevision && s.credentialRevision == ticket.credentialRevision &&',1)
s=s.replace('credentials: credentials, configuration: .init(map: [:]), cancellationToken: .init())','credentials: credentials, configuration: .init(map: [:]), cancellationToken: .init(), credentialContext: credentialContext)',1)
# Capture the active loader, never invent a new credential context for recovery.
s=s.replace('    func automaticSample() -> AbrDiagnosticRecoveryPolicy.Sample {','''    func currentCredentialContext() -> YlHlsCredentialContext? {
      ((player.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)?.credentialContext
    }
    func automaticSample() -> AbrDiagnosticRecoveryPolicy.Sample {''',1).replace('intentRevision: publicHost?.acknowledgedTransportRevision ?? 0)','intentRevision: publicHost?.acknowledgedTransportRevision ?? 0,\n        credentialRevision: currentCredentialContext()?.revision ?? 0)',1)
s=s.replace('"ticketIntentRevision": ticket.intentRevision, "positionBefore":','"ticketIntentRevision": ticket.intentRevision, "ticketCredentialRevision": ticket.credentialRevision, "positionBefore":',1)
needle='''          let replacement = try await Task.detached {
            try YlPreparedHlsAsset(originURL: url, isDash: true, headers: [:],
              configuration: .init(map: [:]), cancellationToken: .init())
          }.value'''
replacement='''          let credentials = try XCTUnwrap(currentCredentialContext())
          let replacement = try await Task.detached {
            try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL: url,
              headers: source.headers, credentials: source.credentials, credentialContext: credentials)
          }.value'''
assert s.count(needle)==2,s.count(needle);s=s.replace(needle,replacement)
# Real readiness followed by real network redirection, no manual invalidation.
s=s.replace('  func testPreparedRecoveryCandidateSharesCredentialStrippingAcrossRedirect() async throws {','  @MainActor func testPreparedRecoveryCandidateSharesCredentialStrippingAcrossRedirect() async throws {',1)
a='''    let (_,response) = try await URLSession.shared.data(from:oldURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)'''
b='''    var policy = AbrDiagnosticRecoveryPolicy()
    var epoch = ProcessInfo.processInfo.systemUptime
    func sample(_ time: Double, width: Int = 320) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time:time,generation:0,allowed:true,width:width,position:time,remaining:120-time,
        bufferAhead:10,bytes:Int64(time*200_000),transfer:time,requests:Int(time*4),overdue:1,
        credentialRevision:context.revision)
    }
    for (time,width) in [(0.0,640),(1.0,320),(9.0,320),(17.0,320)] { _ = policy.observe(sample(time,width:width)) }
    let ticket = try XCTUnwrap(policy.observe(sample(17.5)))
    epoch = ProcessInfo.processInfo.systemUptime
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url: frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent("flutter_assets/assets/test_media/format_matrix/mp4-avc-aac.mp4")
    var redirectsCompleted = false, cleanups = 0
    let prepared = await AbrDiagnosticPreroll.prepare(AVURLAsset(url:media),position:.zero,
      deadlineUptime:epoch+2,allowed:{ policy.authorizes(ticket,sample(17.5+ProcessInfo.processInfo.systemUptime-epoch)) },
      onReady:{
        do {
          let (_,response) = try await URLSession.shared.data(from:oldURL)
          XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200); redirectsCompleted = true
        } catch { XCTFail("Owned redirect request failed") }
      },cancelPending:{ cleanups += 1 })
    await prepared.readyCommand?.value
    XCTAssertTrue(redirectsCompleted); XCTAssertEqual(prepared.outcome,"cancelled")
    XCTAssertTrue(prepared.detached); XCTAssertNil(prepared.item); XCTAssertEqual(cleanups,1)
    XCTAssertFalse(policy.authorizes(ticket,sample(17.5+ProcessInfo.processInfo.systemUptime-epoch)))
    XCTAssertEqual(policy.attempts,1,"A credential change never refunds the source budget")'''
assert a in s;s=s.replace(a,b,1)
# Bounded concurrent context exercise; independent loads remain isolated.
marker='  func testRecoveryCredentialRevisionRevokesTicketAndPreservesBudget() throws {'
s=s.replace(marker,'''  func testCredentialRevisionIsConcurrentIdempotentAndLoadScoped() {
    let context = YlHlsCredentialContext()
    DispatchQueue.concurrentPerform(iterations: 256) { context.strip("resource-\\($0 % 16)") }
    XCTAssertEqual(context.revision,16)
    for index in 0..<16 { XCTAssertTrue(context.isStripped("resource-\\(index)")) }
    XCTAssertEqual(YlHlsCredentialContext().revision,0)
  }

'''+marker,1)
p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');s=p.read_text().replace("{'ios': 842, 'macos': 886}","{'ios': 845, 'macos': 889}");p.write_text(s)
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text().replace('    revision = None; intent_samples = []; ticket_authorities = []','    has_credentials = any(isinstance(r,dict) and \'credentialRevision\' in r for r in rows)\n    credential_revision = None; credential_samples = []\n    revision = None; intent_samples = []; ticket_authorities = []',1)
s=s.replace("        if has_revision:\n            value = row.get('intentRevision')",'''        if has_credentials:
            value = row.get('credentialRevision')
            require(type(value) is int and 0 <= value < 2**64 and (credential_revision is None or value >= credential_revision))
            if credential_revision is not None and value != credential_revision:
                anchor = None; qualified = 0; pending = None
            credential_revision = value
            credential_samples.append(dict(elapsed=row.get('elapsed'), credentialRevision=credential_revision))
        if has_revision:
            value = row.get('intentRevision')''',1).replace("pending = (budget, row['generation'], due, revision)","pending = (budget, row['generation'], due, revision, credential_revision)",1).replace('and pending[3] == revision)','and pending[3] == revision and pending[4] == credential_revision)',1).replace('if has_revision: ticket_authorities.append(dict(attempt=budget,elapsed=elapsed,intentRevision=revision))','if has_revision or has_credentials: ticket_authorities.append(dict(attempt=budget,elapsed=elapsed,intentRevision=revision,credentialRevision=credential_revision))',1).replace('intentSamples=intent_samples, ticketAuthorities=ticket_authorities,','intentSamples=intent_samples, credentialSamples=credential_samples, ticketAuthorities=ticket_authorities,',1)
p.write_text(s)
