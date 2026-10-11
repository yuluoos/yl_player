import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

try:
    import aggregate_experiment as aggregate
except ImportError:
    aggregate = None


def conditions():
    return dict(platform='macos', device='owned-mac', os='macOS-27',
                architecture='arm64', deviceKind='physical', buildMode='debug',
                sourceSha256='a'*64, artifactSha256='b'*64, dependencySha256='c'*64,
                profileId='down-and-recover-v1', profileHash='d'*64, mediaHash='e'*64)


class ExperimentTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(aggregate, 'offline repeated-trial aggregator is missing')
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)

    def plan(self, attempts=1, caches=('os-cache-uncontrolled',)):
        return aggregate.make_plan('owned-1', conditions(), attempts, list(caches))

    def record(self, trial, *, first_frame=100, outcome='completed', exit_code=0,
               recovery=True, rebuffer=None):
        run=trial['runId']; mode=trial['mode']; high=mode=='fixed'
        result=dict(schemaVersion=1,runId=run,mode=mode,platform='macos',buildMode='debug',
                    profileId='down-and-recover-v1',profileHash='d'*64,mediaHash='e'*64,
                    outcome=outcome,cleaned=True,sampleCount=2,firstFrameUs=first_frame,
                    policyAckUs=0,endToEndLatencyUs=None,physicalOutputVerified=False,
                    baselineComparable=False,clockRelation='load-vs-first-get-unsynchronized')
        samples=[dict(runId=run,elapsedUs=t,positionUs=p,status=status,automatic=not high,
                      width=640 if high else 320,height=360 if high else 180,
                      selectedWidth=640 if high else 320,selectedHeight=360 if high else 180,
                      selectedBitrate=700000 if high else 350000,failed=False,
                      rebufferCount=rebuffer,rebufferUs=None) for t,p,status in
                 [(100,0,'playing'),(40000100,40000000,'completed')]]
        rows=[dict(schemaVersion=1,runId=run,requestId=i,profile='down-and-recover-v1',
                   profileSha256='d'*64,timelineMode='first-get',timelineState='active',
                   method='GET',asset=asset,assetSha256=digest,status=200,
                   bodyBytesWritten=100,startMs=start,endMs=start+1,outcome='complete')
              for i,asset,digest,start in [(1,'manifest.mpd','e'*64,0),
                  (2,f'network-period-8/chunk-{1 if high else 0}-00001.m4s','f'*64,
                   26000 if recovery else 2)]]
        contents=dict(capture=''.join('YL_ABR_SAMPLE='+json.dumps(s)+'\n' for s in samples)+
                      'YL_ABR_RESULT='+json.dumps(result)+'\n',
                      requests=''.join(json.dumps(r)+'\n' for r in rows),
                      serverStdout=json.dumps(dict(runId=run,profileSha256='d'*64,timelineMode='first-get'))+'\n'+
                      json.dumps(dict(acceptedConnections=2,rejectedConnections=0,recordedRequests=2))+'\n')
        artifacts={}
        for kind,content in contents.items():
            path=self.root/f'{run}-{kind}.log';path.write_text(content)
            artifacts[kind]=dict(path=path.name,sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        trial.update(artifacts=artifacts,exitCode=exit_code)

    def test_predeclared_matrix_keeps_unrun_rows_and_empty_percentiles(self):
        plan=self.plan(attempts=2,caches=('cold','warm'))
        report=aggregate.summarize_experiment(plan,self.root)
        self.assertEqual(report['planned'],12)
        self.assertEqual(report['statusCounts']['not_run'],12)
        self.assertFalse(report['matrixComplete'])
        self.assertEqual(len(report['cohorts']),6)
        self.assertIsNone(report['cohorts'][0]['metrics']['firstFrameUs']['p95'])

    def test_nearest_rank_percentiles_are_grouped_by_mode_and_cache(self):
        plan=self.plan(attempts=4,caches=('cold','warm'))
        for trial in plan['trials']:
            self.record(trial,first_frame=[100,200,300,1000][trial['attempt']-1]+
                        (10000 if trial['cacheState']=='warm' else 0))
        report=aggregate.summarize_experiment(plan,self.root)
        cold=next(c for c in report['cohorts'] if c['mode']=='auto' and c['cacheState']=='cold')
        warm=next(c for c in report['cohorts'] if c['mode']=='auto' and c['cacheState']=='warm')
        self.assertEqual(cold['metrics']['firstFrameUs'],dict(observed=4,unavailable=0,p50=200,p95=1000))
        self.assertEqual(warm['metrics']['firstFrameUs']['p50'],10200)
        self.assertTrue(report['matrixComplete'])
        self.assertFalse(report['capabilityAccepted'])
        self.assertFalse(report['baselineComparable'])

    def test_timeout_failed_and_unexercised_runs_remain_in_denominator(self):
        plan=self.plan(attempts=2)
        for trial in plan['trials']: self.record(trial)
        self.record(plan['trials'][0],outcome='timeout',exit_code=1)
        self.record(plan['trials'][1],exit_code=1)
        self.record(plan['trials'][2],recovery=False)
        report=aggregate.summarize_experiment(plan,self.root)
        self.assertEqual(report['planned'],6)
        self.assertEqual(report['eligible'],3)
        self.assertEqual(report['statusCounts']['timeout'],1)
        self.assertEqual(report['statusCounts']['failed'],1)
        self.assertEqual(report['statusCounts']['network_not_exercised'],1)

    def test_unknown_metrics_not_zero_and_input_files_unchanged(self):
        plan=self.plan()
        for trial in plan['trials']: self.record(trial)
        before={p.name:p.read_bytes() for p in self.root.iterdir()}
        report=aggregate.summarize_experiment(plan,self.root)
        metric=report['cohorts'][0]['metrics']['rebufferCountDelta']
        self.assertEqual(metric,dict(observed=0,unavailable=1,p50=None,p95=None))
        self.assertEqual(before,{p.name:p.read_bytes() for p in self.root.iterdir()})

    def test_missing_tampered_and_mixed_artifacts_are_retained_as_invalid(self):
        plan=self.plan()
        for trial in plan['trials']: self.record(trial)
        first=plan['trials'][0]['artifacts']['capture']
        (self.root/first['path']).unlink()
        second=plan['trials'][1]['artifacts']['capture']
        (self.root/second['path']).write_text('private-secret')
        plan['trials'][2]['artifacts']['capture']=second.copy()
        report=aggregate.summarize_experiment(plan,self.root)
        self.assertEqual(report['statusCounts']['invalid_artifacts'],3)
        self.assertEqual(report['eligible'],0)
        self.assertNotIn('private-secret',json.dumps(report))

    def test_deleted_trial_duplicate_id_or_malformed_provenance_is_rejected(self):
        for mutate in [lambda p:p['trials'].pop(),
                       lambda p:p['trials'][1].update(runId=p['trials'][0]['runId']),
                       lambda p:p['conditions'].update(device='https://secret.test'),
                       lambda p:p.update(attemptsPerMode=True)]:
            plan=self.plan();mutate(plan)
            with self.assertRaises(ValueError): aggregate.summarize_experiment(plan,self.root)

    def test_path_escape_and_symlink_do_not_read_outside_archive(self):
        plan=self.plan()
        for trial in plan['trials']:self.record(trial)
        ref=plan['trials'][0]['artifacts']['capture'];ref['path']='../secret-file'
        with self.assertRaises(ValueError):aggregate.summarize_experiment(plan,self.root)
        plan=self.plan()
        self.record(plan['trials'][0])
        ref=plan['trials'][0]['artifacts']['capture'];file=self.root/ref['path']
        file.unlink();file.symlink_to('/etc/hosts')
        report=aggregate.summarize_experiment(plan,self.root)
        self.assertEqual(report['trials'][0]['error'],'unsafe_artifact')

    def test_cli_plan_and_incomplete_summary_are_reproducible(self):
        script=Path(__file__).with_name('aggregate_experiment.py')
        (self.root/'conditions.json').write_text(json.dumps(conditions()))
        command=[sys.executable,'-B',str(script),'plan','--conditions',str(self.root/'conditions.json'),
                 '--id','owned-1','--attempts','1','--output',str(self.root/'experiment.json')]
        result=subprocess.run(command,capture_output=True,text=True)
        self.assertEqual((result.returncode,result.stderr),(0,''))
        result=subprocess.run([sys.executable,'-B',str(script),'summarize','--experiment',
                    str(self.root/'experiment.json'),'--output',str(self.root/'report.json')],capture_output=True,text=True)
        self.assertEqual(result.returncode,1)
        self.assertEqual(json.loads((self.root/'report.json').read_text())['statusCounts']['not_run'],3)

    def test_valid_hashes_cannot_mix_run_mode_or_platform_identity(self):
        for change in [dict(runId='other-run'), dict(mode='fixed'), dict(platform='ios')]:
            plan=self.plan();trial=plan['trials'][0];self.record(trial)
            ref=trial['artifacts']['capture'];path=self.root/ref['path']
            lines=path.read_text().splitlines()
            result=json.loads(lines[-1].split('=',1)[1]);result.update(change)
            lines[-1]='YL_ABR_RESULT='+json.dumps(result)
            path.write_text('\n'.join(lines)+'\n')
            ref['sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
            report=aggregate.summarize_experiment(plan,self.root)
            self.assertEqual(report['trials'][0]['status'],'invalid_artifacts')

    def test_policy_failure_does_not_enter_percentiles(self):
        plan=self.plan();trial=next(t for t in plan['trials'] if t['mode']=='caps')
        self.record(trial)
        ref=trial['artifacts']['capture'];path=self.root/ref['path']
        path.write_text(path.read_text().replace('"width": 320','"width": 640'))
        ref['sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
        report=aggregate.summarize_experiment(plan,self.root)
        self.assertEqual(report['statusCounts']['policy_violation'],1)
        self.assertEqual(report['eligible'],0)

    def test_artifact_limit_and_failed_attempt_without_logs_are_retained(self):
        plan=self.plan();trial=plan['trials'][0];self.record(trial)
        path=self.root/trial['artifacts']['serverStdout']['path']
        path.write_bytes(b'x'*65537)
        plan['trials'][1]['exitCode']=1
        report=aggregate.summarize_experiment(plan,self.root)
        self.assertEqual(report['trials'][0]['error'],'artifact_limit')
        self.assertEqual(report['statusCounts']['failed'],1)


if __name__=='__main__':unittest.main()
