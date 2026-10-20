"""Extraction failures are retained as failed evidence, not parser crashes."""
import contextlib
import io
import json
import plistlib
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch
import unittest
import run_bound_flutter_apple as collector
import test_bound_av as fixtures
from bound_artifacts import freeze
from bound_matrix import planned_case
from run_bound_android import parse_rows

class CollectorTest(unittest.TestCase):
    def test_missing_or_malformed_native_records_fail_closed(self):
        for raw in [b'cat: files/missing: No such file or directory\n',b'{}\nBROKEN\n',b'[]\n',b'']:
            rows,valid=parse_rows(raw)
            self.assertFalse(valid)
    def test_json_lines_retained(self):
        rows,valid=parse_rows(b'{"caseId":"one"}\n{"caseId":"two"}\n')
        self.assertTrue(valid);self.assertEqual(['one','two'],[r['caseId'] for r in rows])

class AppleCompletionTest(unittest.TestCase):
    def run_collection(self, started, exits=False):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);app=root/'Runner.app';app.mkdir();out=root/'result'
            (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.test.player'}))
            product=freeze(app,True)
            sample=fixtures.BoundAVTest();sample.setUp()
            catalog=json.loads((Path(__file__).parent/'cases.json').read_text())['cases']
            item=planned_case(catalog,'mkv-avc-eac3','ios','file')
            run='11111111-1111-4111-8111-111111111111'
            sample.plan.update(runId=run,platform='ios',buildSha256=product['sha256'],testSha256=product['sha256'],
                artifactKind='apple-public-flutter-debug-app',planned=[item])
            sample.row.update(runId=run,platform='ios',buildSha256=product['sha256'],testSha256=product['sha256'],
                mediaHash=item['mediaHash'],transport='file',sourceVerified=True,publicSessionId='player-one',publicApi='YlPlayerController/YlPlayerView',
                publicLifecycle=dict(created=True,ready=True,firstFrame=True,completed=True,disposed=True),
                pixelSource='flutter-native-view-display-layer',nativeViewAttached=True,
                audioClockMethod='renderer-paused-consumption',displayReadbackProtocol='paused-layer-timebase-v1',
                windowVisibilityMethod='owned-all-spaces-window-v1')
            for phase in sample.row['phases']:
                phase.update(runId=run,buildSha256=product['sha256'])
                for pixel in phase['pixels']:pixel.update(displayRate=0,windowVisible=True)
                for window in phase['pcmWindows']:window.update(runId=run,buildSha256=product['sha256'])
            status=dict(passed=True,identityVerified=True,artifactsUnchanged=True,runId=run)
            # Prove all raw/framework/artifact evidence is otherwise valid.
            self.assertTrue(collector.acceptance(sample.plan,[sample.row],status,True)['scopeAcceptance'])
            device=Mock();device.has_started.return_value=started;device.stop.return_value=True
            copies=iter([status,None])
            device.read_json.side_effect=lambda name: next(copies) if name=='status.json' else [sample.row] if name=='rows.json' else None
            device.launch_command.return_value=['flutter']
            process=Mock(returncode=0);process.poll.return_value=0 if exits else None
            argv=['collector','--app',str(app),'--out',str(out),'--platform','ios','--device','phone','--case','mkv-avc-eac3']
            with patch('sys.argv',argv), patch.object(collector.uuid,'uuid4',return_value=run), \
                 patch.object(collector,'DeviceTransport',return_value=device), \
                 patch.object(collector.subprocess,'Popen',return_value=process), \
                 patch.object(collector.time,'monotonic',side_effect=[0,1,2,241]), \
                 patch.object(collector.time,'sleep'),contextlib.redirect_stdout(io.StringIO()):
                code=collector.main()
            return code,json.loads((out/'result.json').read_text())

    def test_successful_status_cannot_survive_startup_timeout_and_failed_copy(self):
        code,result=self.run_collection(started=False)
        self.assertEqual(1,code)
        self.assertFalse(result['scopeAcceptance'])
        self.assertEqual('collection_timeout',result['collectorError'])

    def test_early_process_exit_cannot_promote_unconfirmed_status(self):
        code,result=self.run_collection(started=False,exits=True)
        self.assertEqual(1,code)
        self.assertFalse(result['scopeAcceptance'])
        self.assertEqual('process_exited_before_completion',result['collectorError'])

    def test_completed_collection_with_owned_startup_passes(self):
        code,result=self.run_collection(started=True)
        self.assertEqual(0,code)
        self.assertTrue(result['scopeAcceptance'])
        self.assertTrue(result['collectionCompleted'])

if __name__=='__main__':unittest.main()
