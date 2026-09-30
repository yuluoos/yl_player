import unittest
from evidence import summarize


def row(case='av1-main8', policy='systemDefault', generation=0):
    return dict(caseId=case, policy=policy, generation=generation,
                hardwareHint=True, createStatus=0, propertyStatus=0,
                hardwareEvidence='hardware', decodeStatus=0, finishStatus=0,
                waitStatus=0, callbackErrors=0, outputFrames=24,
                expectedFrames=24, geometryErrors=0, pixelFormats=['420v'])


def complete():
    return [row(c, p, g) for c in ['avc-control', 'av1-main8', 'av1-main10']
            for p in ['systemDefault', 'hardwarePreferred', 'hardwareRequired']
            for g in range(2)]


class EvidenceTests(unittest.TestCase):
    def test_complete_decode_evidence_does_not_open_product_or_budget(self):
        result = summarize(complete())
        self.assertEqual(result['av1HardwareDecodeObservations'], 12)
        self.assertFalse(result['productionEnabled'])
        self.assertEqual(result['softwareBudget'], 'unmeasured_not_admitted')

    def test_hint_cannot_replace_actual_session_evidence(self):
        rows = complete()
        for r in rows[6:]: r['hardwareEvidence'] = 'unknown'
        result = summarize(rows)
        self.assertEqual(result['av1HardwareDecodeObservations'], 0)

    def test_creation_failure_is_retained(self):
        rows = complete()
        for r in rows[6:]:
            r.update(createStatus=-12906, propertyStatus=None, hardwareEvidence='unknown',
                     decodeStatus=None, finishStatus=None, waitStatus=None, outputFrames=0)
        result = summarize(rows)
        self.assertEqual(result['av1UnavailableObservations'], 12)
        self.assertEqual(result['observations'], 18)

    def test_recreation_or_output_failure_is_not_hardware_decode(self):
        rows = complete()
        rows[7]['hardwareEvidence'] = 'software'
        rows[8]['outputFrames'] = 0
        rows[9]['geometryErrors'] = 1
        rows[10]['callbackErrors'] = 1
        self.assertEqual(summarize(rows)['av1HardwareDecodeObservations'], 8)

    def test_incomplete_duplicate_and_invalid_values_rejected(self):
        for rows in [complete()[:-1], complete()+[row()], complete()]:
            if len(rows) == 18: rows[0]['createStatus'] = True
            with self.assertRaises(ValueError): summarize(rows)

    def test_broken_positive_control_prevents_capability_conclusion(self):
        rows = complete(); rows[0]['outputFrames'] = 0
        with self.assertRaises(ValueError): summarize(rows)

    def test_hidden_errors_and_partial_frames_do_not_pass(self):
        for field,value in [('decodeStatus',-1),('finishStatus',-1),('waitStatus',-1),('outputFrames',23)]:
            rows=complete();rows[6][field]=value
            self.assertEqual(summarize(rows)['av1HardwareDecodeObservations'],11)

    def test_malfunction_is_not_proof_of_missing_decoder(self):
        rows=complete(); rows[6]["createStatus"]=-12911
        self.assertEqual(summarize(rows)["av1UnavailableObservations"], 0)

    def test_unknown_or_private_fields_are_rejected(self):
        rows=complete();rows[0]['url']='private'
        with self.assertRaises(ValueError): summarize(rows)

if __name__ == '__main__': unittest.main()
