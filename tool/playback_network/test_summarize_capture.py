import unittest
import json
from pathlib import Path
import subprocess
import sys
import tempfile
try:
    from summarize_capture import summarize as _summarize
except ImportError:
    _summarize = None


def summarize(*args, **kwargs):
    kwargs.setdefault('server_summary', dict(acceptedConnections=2,
                      rejectedConnections=0,recordedRequests=2))
    return _summarize(*args, **kwargs)


def data():
    result = dict(schemaVersion=1, runId='run-1', mode='caps', profileId='down-and-recover-v1',
                  profileHash='a'*64, mediaHash='b'*64, outcome='completed', cleaned=True,
                  sampleCount=2, firstFrameUs=100, policyAckUs=50,
                  endToEndLatencyUs=None, physicalOutputVerified=False,
                  baselineComparable=False, clockRelation='load-vs-first-get-unsynchronized')
    samples = [dict(runId='run-1', elapsedUs=t, positionUs=p, status=status,
                    automatic=True, width=320, height=180, selectedWidth=320,
                    selectedHeight=180, selectedBitrate=350000, failed=False,
                    rebufferCount=None, rebufferUs=None) for t,p,status in
                    [(100,0,'playing'), (40000100,40000000,'completed')]]
    requests = [dict(schemaVersion=1, runId='run-1', requestId=1,
        profile='down-and-recover-v1', profileSha256='a'*64,
        timelineMode='first-get', timelineState='active', method='GET',
        asset='manifest.mpd',assetSha256='b'*64, status=200, bodyBytesWritten=100,
        startMs=0,endMs=1,outcome='complete'),
        dict(schemaVersion=1,runId='run-1',requestId=2,profile='down-and-recover-v1',
        profileSha256='a'*64,timelineMode='first-get',timelineState='active',method='GET',
        asset='network-period-8/chunk-0-00001.m4s',assetSha256='c'*64,
        status=200,bodyBytesWritten=100,startMs=26000,endMs=26001,outcome='complete')]
    return result,samples,requests


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(_summarize, 'capture summarizer not implemented')

    def test_missing_native_metrics_and_unsynchronized_clocks_stay_unavailable(self):
        report = summarize(*data(), exit_code=0)
        self.assertTrue(report['captureComplete'])
        self.assertIsNone(report['rebufferCountDelta'])
        self.assertIsNone(report['adaptationLatencyUs'])
        self.assertIsNone(report['endToEndLatencyUs'])
        self.assertFalse(report['capabilityAccepted'])

    def test_caps_checks_requests_and_geometry_independently(self):
        result,samples,requests=data()
        samples[-1]['height']=360
        requests[-1]['asset']='network-period-8/chunk-1-00001.m4s'
        report=summarize(result,samples,requests,exit_code=0)
        self.assertIn('caps_output_exceeded',report['violations'])
        self.assertIn('caps_high_video_requested',report['violations'])

    def test_failure_exit_cleanup_or_lost_rows_cannot_be_a_complete_capture(self):
        result,samples,requests=data()
        self.assertFalse(summarize(result,samples,requests,exit_code=1)['captureComplete'])
        result['cleaned']=False
        self.assertFalse(summarize(result,samples,requests,exit_code=0)['captureComplete'])
        with self.assertRaises(ValueError):
            summarize(result,samples[:-1],requests,exit_code=0)

    def test_mixed_runs_hashes_duplicate_requests_or_reversed_time_rejected(self):
        for mutation in ['run','hash','duplicate','clock']:
            result,samples,requests=data()
            if mutation=='run': requests[-1]['runId']='other'
            if mutation=='hash': requests[0]['assetSha256']='d'*64
            if mutation=='duplicate': requests[-1]['requestId']=1
            if mutation=='clock': samples[-1]['elapsedUs']=0
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):
                summarize(result,samples,requests,exit_code=0)

    def test_counter_resets_or_preloaded_network_dont_claim_recovery(self):
        result,samples,requests=data()
        samples[0]['rebufferCount']=3; samples[-1]['rebufferCount']=1
        requests[-1].update(startMs=2,endMs=3)
        report=summarize(result,samples,requests,exit_code=0)
        self.assertIsNone(report['rebufferCountDelta'])
        self.assertFalse(report['mediaRequestReachedRecovery'])

    def test_fixed_cannot_count_initial_low_frame_as_a_downgrade(self):
        result,samples,requests=data(); result['mode']='fixed'
        samples[0].update(automatic=False,width=640,height=360)
        samples[-1].update(automatic=True,width=320,height=180)
        report=summarize(result,samples,requests,exit_code=0)
        self.assertIn('fixed_returned_to_auto',report['violations'])
        self.assertIn('fixed_output_downgraded',report['violations'])

    def test_missing_request_rows_and_missing_server_shutdown_fail_closed(self):
        result,samples,requests=data()
        requests[-1]['requestId']=3
        with self.assertRaises(ValueError):
            summarize(result,samples,requests,exit_code=0)
        result,samples,requests=data()
        self.assertFalse(summarize(result,samples,requests,exit_code=0,
                                  server_summary=None)['captureComplete'])

    def test_unobserved_fixed_or_changed_auto_mode_is_not_policy_success(self):
        result,samples,requests=data();result['mode']='fixed'
        self.assertIn('fixed_high_unobserved',summarize(result,samples,requests,exit_code=0)['violations'])
        result['mode']='auto';samples[-1]['automatic']=False
        self.assertIn('auto_mode_not_retained',summarize(result,samples,requests,exit_code=0)['violations'])

    def test_fixed_auto_after_ack_is_detected_before_first_high_frame(self):
        result,samples,requests=data();result['mode']='fixed'
        report=summarize(result,samples,requests,exit_code=0)
        self.assertIn('fixed_returned_to_auto',report['violations'])

    def test_phase_coverage_uses_writes_not_a_request_ending_after_recovery(self):
        result, samples, requests = data()
        report = summarize(result, samples, requests, exit_code=0)
        self.assertIsNone(report.get('networkPhaseBytes'))
        self.assertFalse(report.get('networkPhasesCovered', True))
        for row in requests:
            row['phaseBoundariesMs'] = [0, 10000, 25000]
            row['phaseBytesWritten'] = [0, 0, row['bodyBytesWritten']]
        report = summarize(result, samples, requests, exit_code=0)
        self.assertEqual(report['networkPhaseBytes'], [0, 0, 100])
        self.assertFalse(report['networkPhasesCovered'])
        requests[-1]['phaseBytesWritten'] = [20, 30, 50]
        self.assertTrue(summarize(result, samples, requests, exit_code=0)['networkPhasesCovered'])
        requests[-1]['phaseBytesWritten'] = [20, 30, 51]
        with self.assertRaises(ValueError):
            summarize(result, samples, requests, exit_code=0)

    def test_cli_roundtrip_and_truncated_capture_exit(self):
        result,samples,requests=data()
        with tempfile.TemporaryDirectory() as work:
            root=Path(work)
            capture=root/'capture.log'
            capture.write_text(''.join('YL_ABR_SAMPLE='+json.dumps(s)+'\n' for s in samples)+
                               'YL_ABR_RESULT='+json.dumps(result)+'\n')
            (root/'requests.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in requests))
            (root/'server.jsonl').write_text(json.dumps(dict(runId='run-1',profileSha256='a'*64,timelineMode='first-get'))+'\n'+
                json.dumps(dict(acceptedConnections=2,rejectedConnections=0,recordedRequests=2))+'\n')
            command=[sys.executable,'-B',str(Path(__file__).with_name('summarize_capture.py')),
                     '--capture',str(capture),'--requests',str(root/'requests.jsonl'),
                     '--server-stdout',str(root/'server.jsonl'),'--exit-code','0','--output',str(root/'out.json')]
            completed=subprocess.run(command,capture_output=True,text=True)
            self.assertEqual((completed.returncode,completed.stderr),(0,''))
            self.assertFalse(json.loads((root/'out.json').read_text())['capabilityAccepted'])
            capture.write_text('YL_ABR_RESULT='+json.dumps(result)+'\n')
            command[-1]=str(root/'bad.json')
            truncated=subprocess.run(command,capture_output=True,text=True)
            self.assertEqual(truncated.returncode,2)
            self.assertFalse((root/'bad.json').exists())


if __name__=='__main__': unittest.main()
