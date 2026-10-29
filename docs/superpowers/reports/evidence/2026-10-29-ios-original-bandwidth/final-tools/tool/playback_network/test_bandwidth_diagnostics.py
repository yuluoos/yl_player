"""Bandwidth observations retain transport overhead and concurrency explicitly."""
import copy
import unittest
import network_profile as net
try:
    from bandwidth_diagnostics import summarize_requests
except ImportError:
    summarize_requests = None


class BandwidthDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(summarize_requests)
        self.profile = net.Profile(dict(id='diagnostic-v1', steps=[
            dict(atMs=0, bytesPerSecond=500000, latencyMs=40),
            dict(atMs=1000, bytesPerSecond=50000, latencyMs=200)]))

    def row(self, ident, start, end, size=10000, **values):
        row = dict(schemaVersion=1, requestId=ident, profile=self.profile.id,
            profileSha256=self.profile.sha256, phaseBoundariesMs=[0,1000],
            phaseBytesWritten=[size,0], bodyBytesWritten=size, startMs=start,
            endMs=end, method='GET', status=200, outcome='complete',
            timelineState='active', timelineMode='first-get', runId='fixture')
        row.update(values)
        return row

    def test_overlapping_requests_keep_sum_and_union_distinct(self):
        result = summarize_requests([self.row(2,50,150), self.row(1,0,100)], self.profile)
        phase = result['phases'][0]
        self.assertEqual(phase['requestCount'], 2)
        self.assertEqual(phase['requestDurationSumMs'], 200)
        self.assertEqual(phase['activeUnionMs'], 150)
        self.assertEqual(phase['requestWeightedGoodputBps'], 800000)
        self.assertAlmostEqual(phase['activeUnionGoodputBps'], 20000*8000/150)
        self.assertEqual(phase['configuredLatencySumMs'], 80)
        self.assertEqual(phase['configuredCeilingBps'], 4000000)
        self.assertFalse(result['capacityMeasured'])
        self.assertFalse(result['capabilityAccepted'])

    def test_cross_boundary_failure_and_head_are_counted_not_qualified(self):
        rows = [self.row(1,950,1050,phaseBytesWritten=[5000,5000]),
            self.row(2,1100,1200,phaseBytesWritten=[0,10000],outcome='client_io_error'),
            self.row(3,100,120,0,method='HEAD'),
            self.row(4,1300,1500,phaseBytesWritten=[0,10000])]
        result = summarize_requests(rows,self.profile)
        self.assertEqual(result['excludedCounts'], {'crossPhase':1,'incompleteOrNonBody':2})
        self.assertEqual(result['totalRequests'],4)
        self.assertEqual(result['phases'][0]['requestCount'],0)
        self.assertIsNone(result['phases'][0]['requestWeightedGoodputBps'])
        self.assertEqual(result['phases'][1]['requestCount'],1)

    def test_rejects_mixed_profile_duplicate_ids_and_invalid_timings(self):
        changes = [dict(profile='wrong-v1'),dict(profileSha256='x'),
            dict(startMs=float('nan')),dict(endMs=0),dict(bodyBytesWritten=True),
            dict(phaseBytesWritten=[1,0]),dict(phaseBoundariesMs=[0,999]),
            dict(timelineMode='server-start'),dict(runId='different')]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                summarize_requests([self.row(1,0,100),self.row(2,100,200,**change)],self.profile)
        with self.assertRaises(ValueError):
            summarize_requests([self.row(1,0,100),self.row(1,100,200)],self.profile)

    def test_sum_counts_nested_intervals_without_double_counting_union(self):
        rows=[self.row(1,0,500),self.row(2,20,100),self.row(3,100,200),self.row(4,600,700)]
        phase=summarize_requests(rows,self.profile)['phases'][0]
        self.assertEqual(phase['activeUnionMs'],600)
        self.assertEqual(phase['requestDurationSumMs'],780)
        self.assertEqual(phase['spanMs'],700)

    def test_phase_boundary_endpoint_belongs_to_completed_earlier_phase(self):
        rows=[self.row(1,900,1000),self.row(2,1000,1200,phaseBytesWritten=[0,10000])]
        result=summarize_requests(rows,self.profile)
        self.assertEqual([p['requestCount'] for p in result['phases']],[1,1])
        self.assertEqual(result['excludedCounts'], {'crossPhase':0,'incompleteOrNonBody':0})

    def test_input_is_not_mutated_and_empty_capture_is_rejected(self):
        rows=[self.row(1,0,100)]; before=copy.deepcopy(rows)
        summarize_requests(rows,self.profile)
        self.assertEqual(rows,before)
        with self.assertRaises(ValueError): summarize_requests([],self.profile)
