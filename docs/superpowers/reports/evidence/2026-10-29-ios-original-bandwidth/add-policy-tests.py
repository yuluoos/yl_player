from pathlib import Path
p=Path('tool/playback_network/test_abr_policy.py');s=p.read_text();mark='    def test_reservation_and_ticket_preserve_frozen_limits(self):'
s=s.replace(mark,'''    def test_completed_window_rejection_matches_guard_priority_and_threshold(self):
        start = dict(row(1, 'windowStarted'), bytes=0, transfer=1, requests=4,
                     windowBitrate=None, windowRequests=None)
        low = dict(row(), bytes=954999, windowBitrate=954999)
        self.summary([start, low])
        no_progress = dict(low, reason='noProgress', position=1)
        few_requests = dict(low, reason='insufficientRequests', requests=6, windowRequests=2)
        self.summary([start, no_progress])
        self.summary([start, few_requests])
        # An exact-threshold window is qualified, and a higher-priority failed
        # guard cannot be relabelled as a bandwidth problem.
        invalid = [dict(low, bytes=955000, windowBitrate=955000),
                   dict(low, bytes=955001, windowBitrate=955001),
                   dict(low, reason='noProgress'),
                   dict(low, reason='insufficientRequests'),
                   dict(no_progress, reason='insufficientBandwidth'),
                   dict(few_requests, reason='insufficientBandwidth'),
                   dict(few_requests, reason='insufficientRequests', position=1)]
        for sample in invalid:
            with self.subTest(sample=sample), self.assertRaises(ValueError):
                self.summary([start, sample])

'''+mark)
p.write_text(s)
