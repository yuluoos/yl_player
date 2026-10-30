import unittest
try:
    from server_timing import RequestTiming, summarize_server_timing
except ImportError:
    RequestTiming = summarize_server_timing = None

class TimingTests(unittest.TestCase):
    def setUp(self): self.assertIsNotNone(RequestTiming)

    def test_nested_sleep_and_failure_are_measured_without_hiding_missing_work(self):
        clock=[0.0]; t=RequestTiming(lambda:clock[0])
        with t.measure('latency'):pass
        with t.measure('headerWrite'):pass
        with t.measure('queue'):pass
        with t.measure('hold'):
            t.requested_sleep(.1)
            with t.measure('sleep'):clock[0]+=.15
        with self.assertRaises(OSError):
            with t.measure('bodyWrite'):clock[0]+=.02;raise OSError('fixture')
        result=t.finish()
        self.assertAlmostEqual(result['sleepSeconds'],.15)
        self.assertEqual(result['sleepRequestedSeconds'],.1)
        self.assertEqual(result['bodyWriteFailures'],1)
        self.assertEqual(result['queueCalls'],1)
        self.assertTrue(summarize_server_timing([dict(serverTiming=result,method='GET',outcome='client_io_error',bodyBytesWritten=0,timelineState='active')])['complete'])

    def test_invalid_clock_and_corrupted_partitions_fail_closed(self):
        clock=[0.0];t=RequestTiming(lambda:clock[0])
        with t.measure('latency'):clock[0]=-.1
        self.assertFalse(t.finish()['valid'])
        with self.assertRaises(ValueError):summarize_server_timing([dict(serverTiming=t.finish())])
        t=RequestTiming(lambda:0);valid=t.finish()
        for mutate in [dict(valid,sleepSeconds=1),dict(valid,bodyWriteFailures=1),dict(valid,queueCalls=True),dict(valid,extra='secret')]:
            with self.subTest(mutate=mutate),self.assertRaises(ValueError):summarize_server_timing([dict(serverTiming=mutate)])
        with self.assertRaises(ValueError):summarize_server_timing([{}])


class ReaderIntegrityTests(unittest.TestCase):
    def row(self):
        t=RequestTiming(lambda:0)
        with t.measure('headerWrite'):pass
        return dict(serverTiming=t.finish(),method='HEAD',outcome='complete',bodyBytesWritten=0,timelineState='pending')

    def test_impossible_stages_and_missing_success_header_are_rejected(self):
        for changes in [dict(headerWriteCalls=0),dict(bodyWriteCalls=1,bodyWriteSeconds=1,totalSeconds=1),dict(sleepCalls=1),dict(queueCalls=1),dict(holdCalls=1)]:
            row=self.row();row['serverTiming'].update(changes)
            with self.subTest(changes=changes),self.assertRaises(ValueError):summarize_server_timing([row])

    def test_successful_body_requires_observed_shaper_sleep(self):
        row=self.row();row.update(method='GET',timelineState='active',bodyBytesWritten=1)
        row['serverTiming'].update(latencyCalls=1,queueCalls=1,holdCalls=1,bodyWriteCalls=1)
        with self.assertRaises(ValueError):summarize_server_timing([row])

    def test_large_numbers_and_aggregate_overflow_fail_as_value_errors(self):
        row=self.row();row['serverTiming']['queueCalls']=10**400
        with self.assertRaises(ValueError):summarize_server_timing([row])
        row=self.row();row['serverTiming']['totalSeconds']=1e308
        with self.assertRaises(ValueError):summarize_server_timing([row,row])

if __name__=='__main__':unittest.main()
