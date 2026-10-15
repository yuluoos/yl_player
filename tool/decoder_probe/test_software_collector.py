import copy
import json
import unittest
from run_software import decode_raw

class CollectorTests(unittest.TestCase):
    def raw(self):
        samples=[dict(slot=i,monotonicNs=i*250_000_000) for i in range(65)]
        return [dict(sample=s) for s in samples]+[dict(status='passed',samples=samples,decodedFrames=288)]
    def text(self, rows):return '\n'.join(json.dumps(r) for r in rows)
    def test_complete_raw_samples_bound_to_result(self):
        self.assertEqual(288,decode_raw(self.text(self.raw()))['decodedFrames'])
    def test_truncated_duplicate_reordered_and_forged_result_rejected(self):
        raw=self.raw()
        changes=[raw[:-1],raw[:10]+raw[11:],raw[:10]+[raw[9]]+raw[10:]]
        changed=copy.deepcopy(raw);changed[1],changed[2]=changed[2],changed[1];changes.append(changed)
        changed=copy.deepcopy(raw);changed[-1]['samples']=copy.deepcopy(changed[-1]['samples']);changed[-1]['samples'][0]['monotonicNs']=123;changes.append(changed)
        for rows in changes:
            with self.subTest(rows=len(rows)):
                with self.assertRaises(ValueError):decode_raw(self.text(rows))

if __name__=='__main__':unittest.main()

class AdmissionEvidenceTests(unittest.TestCase):
    def test_copied_or_unbound_process_rows_cannot_be_independent(self):
        from pathlib import Path
        from tempfile import TemporaryDirectory
        from run_software import check_admission, digest, canonical
        import hashlib
        with TemporaryDirectory() as directory:
            roots=[Path(directory)/name for name in ('baseline','verification')]
            for root in roots:
                root.mkdir()
                protocol={'key':{'model':'same'},'fixtureSha256':'a'*64}
                (root/'protocol.json').write_text(json.dumps(protocol))
                raw='\n'.join(json.dumps(row) for row in CollectorTests().raw())
                (root/'run-0.jsonl').write_text(raw)
                result={'runStatus':'collected','protocolSha256':hashlib.sha256(canonical(protocol)).hexdigest(),
                        'rows':[dict(run=0,runId='copied',rawSha256=digest(root/'run-0.jsonl'))]}
                (root/'result.json').write_text(json.dumps(result))
            with self.assertRaises(ValueError):check_admission(*roots)

class PositiveControlTests(unittest.TestCase):
    def test_each_actual_policy_and_recreation_is_required(self):
        from run_software import valid_control
        rows=[dict(caseId='avc-control',policy=policy,generation=g,hardwareEvidence='hardware',
            createStatus=0,outputFrames=96,callbackErrors=0,geometryErrors=0,decodeStatus=0,finishStatus=0,waitStatus=0)
            for policy in ('systemDefault','hardwarePreferred','hardwareRequired') for g in (0,1)]
        self.assertTrue(valid_control(rows))
        self.assertFalse(valid_control([rows[0]]*6))
        rows[-1]['hardwareEvidence']='unknown'
        self.assertFalse(valid_control(rows))
