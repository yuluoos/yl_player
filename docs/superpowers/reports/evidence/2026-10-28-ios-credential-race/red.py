from pathlib import Path
import sys
p=Path('docs/superpowers/plans/2026-10-28-ios-credential-race.md');p.write_text('''# iOS 恢复候选凭据竞争

基线7a089625；沿用已授权剩余项，当前worktree内实施，系统排障/TDD/集中验收，不发布。

约束：只修复已确认诊断路径；生产仅增加凭据上下文只读版本。保留原失败，2秒准备/5秒票据/双8秒窗/955000bit/s/预算2/500、1000ms退避不变。无生产自动恢复入口。

- [ ] 抽取现有诊断候选准备路径；复现准备期间跨源剥离后旧票据仍获准、候选独立上下文丢失剥离记录。
- [ ] 上下文提供只读单调revision（不同资源剥离才增长），诊断Sample/Ticket绑定；版本变化重建窗口、预算不退款。候选共享当前loader上下文及请求元数据。
- [ ] 本地真实跨源返回请求验证：原候选废弃；后续candidate相同资源无Authorization/Cookie/显式credential，普通header保留；重复strip不增版本，独立Load不继承。
- [ ] Python重放拒绝凭据版本倒退、缺字段、跨版本窗口和票据；记录版本，不记录凭据内容。
- [ ] 集中受影响Apple双平台/网络工具/台账测试、一次独立综合复审、归档完整原始记录并更新发布台账。

复审重点：并发strip幂等；上下文归属不能跨Load；真正网络redirect导致撤权而非手工作废；候选必须释放，源预算不退款；凭据值不可进入诊断证据。完整公开/Dart凭据竞争、ABR高档恢复及物理连续性仍需单独验收。
''')
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsHeaderPolicy.swift');s=p.read_text().replace('  func isStripped(_ resource: String) -> Bool {','  var revision: UInt64 {\n    lock.lock(); defer { lock.unlock() }\n    return UInt64(strippedResources.count)\n  }\n\n  func isStripped(_ resource: String) -> Bool {',1);p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text().replace('    var intentRevision: UInt64 = 0','    var intentRevision: UInt64 = 0\n    var credentialRevision: UInt64 = 0',1)
# Extract the existing implementation before changing its missing context propagation.
s=s.replace('private enum AbrDiagnosticCandidatePreparation {','''private enum AbrDiagnosticCandidatePreparation {
  static func prepareReplacement(originURL: URL, headers: [String: String], credentials: [String: String],
    credentialContext: YlHlsCredentialContext) throws -> YlPreparedHlsAsset {
    try YlPreparedHlsAsset(originURL: originURL, isDash: true, headers: headers,
      credentials: credentials, configuration: .init(map: [:]), cancellationToken: .init())
  }
''',1)
marker='  func testRecoveryTicketRejectsAcknowledgedIntentRevisionWithoutItemChange() throws {'
test='''  func testRecoveryCredentialRevisionRevokesTicketAndPreservesBudget() throws {
    var policy = AbrDiagnosticRecoveryPolicy()
    func sample(_ time: Double, width: Int = 320, revision: UInt64 = 0) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time: time, generation: 0, allowed: true, width: width, position: time,
        remaining: 120-time, bufferAhead: 10, bytes: Int64(time*200_000), transfer: time,
        requests: Int(time*4), overdue: 1, credentialRevision: revision)
    }
    for (time,width) in [(0.0,640),(1.0,320),(9.0,320),(17.0,320)] { _ = policy.observe(sample(time,width:width)) }
    let old = try XCTUnwrap(policy.observe(sample(17.5)))
    XCTAssertFalse(policy.authorizes(old,sample(17.6,revision:1)), "Credential stripping revokes authority without an item or transport change")
    _ = policy.observe(sample(18,revision:1))
    policy.finish(old)
    XCTAssertEqual(policy.attempts,1)
    _ = policy.observe(sample(26,revision:1)); _ = policy.observe(sample(34,revision:1))
    XCTAssertNil(policy.observe(sample(34.99,revision:1)))
    let next = try XCTUnwrap(policy.observe(sample(35,revision:1)))
    XCTAssertEqual(next.attempt,2); XCTAssertTrue(policy.authorizes(next,sample(35.1,revision:1)))
    XCTAssertFalse(policy.authorizes(old,sample(35.1,revision:1)))
  }

  func testPreparedRecoveryCandidateSharesCredentialStrippingAcrossRedirect() async throws {
    let server = try DashHTTPServer(), other = try DashHTTPServer()
    defer { server.close(); other.close() }
    let data = mpd
    server.handler = { request in
      if request.path == "/movie.mpd" { return (200,[:],data) }
      if request.path == "/seg-1.m4s" { return (302,["Location":other.url("/hop").absoluteString],Data()) }
      return (200,[:],Data([1,2,3]))
    }
    other.handler = { _ in (302,["Location":server.url("/return").absoluteString],Data()) }
    let context = YlHlsCredentialContext()
    let current = try YlPreparedHlsAsset(originURL:server.url("/movie.mpd"),isDash:true,
      headers:["Authorization":"fixture","Cookie":"fixture","X-Client":"ordinary"],credentials:["X-Session":"fixture"],
      configuration:.init(map:[:]),cancellationToken:.init(),credentialContext:context)
    defer { current.discard() }
    let candidate = try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL:server.url("/movie.mpd"),
      headers:["Authorization":"fixture","Cookie":"fixture","X-Client":"ordinary"],credentials:["X-Session":"fixture"],credentialContext:context)
    defer { candidate.discard() }
    func segment(_ prepared:YlPreparedHlsAsset) throws -> URL {
      let master = read(prepared.loader,prepared.asset.url)
      let video = read(prepared.loader,try child(master.received))
      return try XCTUnwrap(String(decoding:video.received,as:UTF8.self).split(separator:"\\n").first { $0.hasPrefix("http:") }.flatMap { URL(string:String($0)) })
    }
    let oldURL = try segment(current), candidateURL = try segment(candidate)
    XCTAssertEqual(context.revision,0)
    let (_,response) = try await URLSession.shared.data(from:oldURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
    XCTAssertTrue(context.isStripped(server.url("/seg-1.m4s").absoluteString))
    XCTAssertEqual(context.revision,1)
    XCTAssertTrue(candidate.loader.credentialContext === context, "A prepared recovery must keep its user Load credential history")
    let (_,nextResponse) = try await URLSession.shared.data(from:candidateURL)
    XCTAssertEqual((nextResponse as? HTTPURLResponse)?.statusCode,200)
    let requests = server.requests.filter { $0.path == "/seg-1.m4s" }
    XCTAssertEqual(requests.count,2); XCTAssertEqual(requests.first?.headers["authorization"],"fixture")
    XCTAssertNil(requests.last?.headers["authorization"]); XCTAssertNil(requests.last?.headers["cookie"])
    XCTAssertNil(requests.last?.headers["x-session"]); XCTAssertEqual(requests.last?.headers["x-client"],"ordinary")
    for r in other.requests + server.requests.filter({ $0.path == "/return" }) {
      XCTAssertNil(r.headers["authorization"]); XCTAssertNil(r.headers["cookie"]); XCTAssertNil(r.headers["x-session"])
    }
    XCTAssertEqual(context.revision,1,"Repeated stripping of the same resource is idempotent")
    XCTAssertEqual(YlHlsCredentialContext().revision,0,"A different user Load has its own history")
  }

'''
assert marker in s;s=s.replace(marker,test+marker,1);p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
