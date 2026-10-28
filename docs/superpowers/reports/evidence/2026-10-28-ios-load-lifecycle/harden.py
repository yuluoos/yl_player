from pathlib import Path
import sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();start=s.index('  @MainActor func testPublicLoadCredentialHistory');end=s.index('  @MainActor func testSameDashCandidate',start);a=s[start:end]
a=a.replace('if request.path == "/seg-1.m4s" {','if request.path == "/seg-1.m4s" && request.headers["range"] == "bytes=1-2" {',1)
a=a.replace('    let first = try await fixture.host.load', '''    func fetch(_ url:URL) async throws -> URLResponse {
      // Distinguish the controlled redirect from AVPlayer's own read-ahead.
      var request = URLRequest(url:url); request.setValue("bytes=1-2",forHTTPHeaderField:"Range")
      return try await URLSession.shared.data(for:request).1
    }
    let first = try await fixture.host.load''',1).replace('let (_,response) = try await URLSession.shared.data(from:oldURL)','let response = try await fetch(oldURL)').replace('_ = try await URLSession.shared.data(from:oldURL)','_ = try await fetch(oldURL)').replace('_ = try await URLSession.shared.data(from:segment(newLoader))','_ = try await fetch(segment(newLoader))').replace('$0.path == "/seg-1.m4s" })','$0.path == "/seg-1.m4s" && $0.headers["range"] == "bytes=1-2" })')
s=s[:start]+a+s[end:]
s=s.replace('snap["cancelledCompletions",default:0]>0 && server.peerClosed>0','snap["cancelledCompletions",default:0]>0 && snap["upstreamCompletions"]==snap["admittedRequests"] &&\n        server.peerClosed>0 && server.peerClosed==server.heldCount',1)
s=s.replace('  private var closed = 0\n  var peerClosed:', '  private var closed = 0\n  private var held = 0\n  var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held }\n  var peerClosed:',1).replace('''        } else {
          let header = "HTTP/1.1 200 OK\\r\\nContent-Type: video/mp4''','''        } else {
          self.lock.lock(); self.held += 1; self.lock.unlock()
          let header = "HTTP/1.1 200 OK\\r\\nContent-Type: video/mp4''',1)
p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
