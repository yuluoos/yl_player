from pathlib import Path
import shutil,json,subprocess
raw=Path('/private/tmp/yl-public-race');shutil.copytree(raw/'capture-source',raw/'before-deadline-source');shutil.copy2(raw/'source-identity.json',raw/'before-deadline-source-identity.json')
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text()
old='''      var allowed = true, invoked = false, cleanups = 0
      let result = await AbrDiagnosticPreroll.prepare(AVURLAsset(url: media), position: .zero,
'''
new='''      var allowed = true, invoked = false, cleanups = 0
      var commandFinished = false, cleanedWhileCommandPending = false
      let release = Task { @MainActor in
        if expire {
          try? await Task.sleep(nanoseconds: 2_200_000_000)
          cleanedWhileCommandPending = cleanups == 1 && !commandFinished
          commandFinished = true
        }
      }
      defer { release.cancel() }
      let result = await AbrDiagnosticPreroll.prepare(AVURLAsset(url: media), position: .zero,
'''
assert s.count(old)==1;s=s.replace(old,new)
s=s.replace('''          if expire { try? await Task.sleep(nanoseconds: 2_000_000_000) }
          else { await Task.yield(); allowed = false }
''','''          if expire {
            while !commandFinished { try? await Task.sleep(nanoseconds: 10_000_000) }
          } else { await Task.yield(); allowed = false; commandFinished = true }
''',1)
s=s.replace('''      XCTAssertTrue(invoked, "Must exercise the callback after actual readiness")
''','''      await release.value
      if expire { XCTAssertTrue(cleanedWhileCommandPending, "Deadline must detach and cancel while the public command is still pending") }
      XCTAssertTrue(invoked, "Must exercise the callback after actual readiness")
''',1);p.write_text(s)
import sys
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
cmd=json.loads((raw/'final-macos-contracts-command.json').read_text());cmd=[x for x in cmd if not x.startswith('-only-testing:')];cmd[cmd.index('-resultBundlePath')+1]=str(raw/'deadline-red.xcresult');cmd+=['-only-testing:RunnerTests/YlDashResourceLoaderTests/testPrerollRevalidatesIntentAndDeadlineAfterAsyncReadyCommand']
(raw/'deadline-red-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (raw/'deadline-red.log').open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(raw/'deadline-red-result.json').write_text(json.dumps({'exitCode':r.returncode})+'\n');print(r.returncode)
