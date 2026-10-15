"""Synthetic accounting evidence is never a device qualification artifact."""
import copy
import hashlib
import json
import unittest
from software_evidence import summarize


def fixture():
    key = dict(model='synthetic', osBuild='test-os', decoderBuild='a'*64,
               codec=12, profile=0, bitDepth=8, chroma=420, width=16, height=16,
               fpsNumerator=24, fpsDenominator=1, threads=1, outputPixelFormat=1)
    protocol = dict(schemaVersion=1, key=key, fixtureSha256='b'*64,
                    buildMode='release', simulator=False, repetitions=5,
                    idleNs=2_000_000_000, decodeNs=12_000_000_000,
                    disposeNs=2_000_000_000, sampleIntervalNs=250_000_000,
                    sustainedThermalVerified=False)
    rows = []
    for i in range(5):
        rows.append(dict(run=i, runId=f'process-{i}', key=key.copy(),
            fixtureSha256='b'*64, buildMode='release', simulator=False,
            protocolSha256=hashlib.sha256(json.dumps(protocol,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
            status='passed', outputMarkersVerified=True, positiveControlPassed=True,
            decodedFrames=288, rawSha256=str(i)*64,
            samples=[dict(monotonicNs=j*250_000_000, cpuNs=j*10_000_000,
                          rssBytes=1024, footprintBytes=2048, thermal='nominal',
                          lowPower=False) for j in range(65)]))
    return protocol, rows


class SoftwareEvidenceTests(unittest.TestCase):
    def test_complete_short_run_is_measured_but_not_admitted(self):
        p,r=fixture(); s=summarize(p,r)
        self.assertTrue(s['measurementValid'])
        self.assertFalse(s['productionEligible'])
        self.assertIn('sustained_thermal_missing',s['admissionBlockers'])
        self.assertIn('independent_verification_missing',s['admissionBlockers'])
        self.assertEqual(s['peakFootprintBytes'],2048)

    def test_real_apple_two_image_identity_and_actual_sampling_jitter(self):
        p,r=fixture();p['key']['decoderBuild']='a'*64+':'+ 'b'*64
        p['maxSampleLatenessNs']=50_000_000
        for row in r:
            row['key']=p['key'].copy()
            row['protocolSha256']=hashlib.sha256(json.dumps(p,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            for i,sample in enumerate(row['samples']):
                sample['slot']=i;sample['monotonicNs']+=1_000_000
        self.assertTrue(summarize(p,r)['measurementValid'])
        r[0]['samples'][10]['monotonicNs']+=51_000_000
        self.assertFalse(summarize(p,r)['measurementValid'])

    def test_missing_duplicate_and_failed_runs_are_invalid(self):
        p,r=fixture()
        for rows in (r[:-1],r+[r[0]],r[:1]*5):
            self.assertFalse(summarize(p,rows)['measurementValid'])
        for field,value in [('status','skipped'),('outputMarkersVerified',False),
                            ('positiveControlPassed',False),('decodedFrames',0),
                            ('fixtureSha256','c'*64)]:
            with self.subTest(field=field):
                rows=copy.deepcopy(r);rows[0][field]=value
                self.assertFalse(summarize(p,rows)['measurementValid'])

    def test_samples_require_complete_monotonic_known_process_counters(self):
        p,r=fixture()
        for field,value in [('cpuNs',-1),('monotonicNs',0),('rssBytes',0),
                            ('footprintBytes',True),('thermal',None),('lowPower',None)]:
            with self.subTest(field=field):
                rows=copy.deepcopy(r);rows[0]['samples'][1][field]=value
                self.assertFalse(summarize(p,rows)['measurementValid'])
        rows=copy.deepcopy(r); rows[0]['samples'].pop(20)
        self.assertFalse(summarize(p,rows)['measurementValid'])
        rows=copy.deepcopy(r); rows[0]['samples'][20]['cpuNs']=0
        self.assertFalse(summarize(p,rows)['measurementValid'])

    def test_environment_and_hash_changes_do_not_qualify(self):
        p,r=fixture()
        for field,value in [('model','unknown'),('osBuild','other'),('decoderBuild','bad'),
                            ('fpsNumerator',0),('width',2**63)]:
            rows=copy.deepcopy(r);rows[0]['key'][field]=value
            self.assertFalse(summarize(p,rows)['measurementValid'])
        for mode,sim in [('debug',False),('release',True)]:
            pp=copy.deepcopy(p);pp.update(buildMode=mode,simulator=sim)
            rows=copy.deepcopy(r)
            for row in rows:
                row.update(buildMode=mode,simulator=sim,
                    protocolSha256=hashlib.sha256(json.dumps(pp,sort_keys=True,separators=(',',':')).encode()).hexdigest())
            self.assertTrue(summarize(pp,rows)['measurementValid'])
            self.assertFalse(summarize(pp,rows)['productionEligible'])

    def test_a_claimed_thermal_flag_cannot_replace_verified_evidence(self):
        p,r=fixture();p['sustainedThermalVerified']=True
        s=summarize(p,r)
        self.assertFalse(s['productionEligible'])
        self.assertIn('sustained_thermal_missing',s['admissionBlockers'])

    def test_each_process_must_bind_exact_predeclared_protocol(self):
        p,r=fixture()
        r[0]['protocolSha256']='f'*64
        self.assertFalse(summarize(p,r)['measurementValid'])

    def test_protocol_cannot_relax_fixed_measurement_requirements(self):
        p,r=fixture()
        for field,value in [('repetitions',1),('sampleIntervalNs',500_000_000),
                            ('decodeNs',1),('schemaVersion',2)]:
            pp=copy.deepcopy(p);pp[field]=value
            self.assertFalse(summarize(pp,r)['measurementValid'])

if __name__=='__main__':unittest.main()
