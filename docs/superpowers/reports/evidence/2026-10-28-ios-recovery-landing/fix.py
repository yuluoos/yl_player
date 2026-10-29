from pathlib import Path
import sys
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift');s=p.read_text()
a='''            self.pendingUserSeek = nil
            if finished {'''
b='''            if !finished, let resumeId, self.pendingRuntimeResume?.id == resumeId,
               self.videoSelection.fixedTrackId == nil {
              self.failRuntimeResume()
              return
            }
            self.pendingUserSeek = nil
            if finished {'''
assert s.count(a)==1;s=s.replace(a,b)
a='''            self.pendingRuntimeResume = nil
            if finished {'''
b='''            if !finished, self.videoSelection.fixedTrackId == nil {
              self.failRuntimeResume()
              return
            }
            self.pendingRuntimeResume = nil
            if finished {'''
assert s.count(a)==1;s=s.replace(a,b)
a='''  private func observe(_ item: AVPlayerItem, generation: UInt64) {'''
b='''  private func failRuntimeResume() {
    // The replacement already owns the item. A failed exact landing has no
    // authority to publish its default timeline, even after a public seek.
    reportRestorationFailure(NativePlayerError(category: "source", code: "source.seek_failed",
      message: "The playback position could not be restored."))
  }

'''+a
assert s.count(a)==1;s=s.replace(a,b);p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();at=s.index('  @MainActor func testAutomaticReplacementFailedLandingCannotPublishWrongTimeline')
s=s[:at]+Path('/private/tmp/yl-recovery-landing/more-tests.txt').read_text()+s[at:];p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');s=p.read_text();assert "EXPECTED_CASES = {'ios': 863, 'macos': 907}" in s;s=s.replace("EXPECTED_CASES = {'ios': 863, 'macos': 907}","EXPECTED_CASES = {'ios': 867, 'macos': 911}");p.write_text(s)
