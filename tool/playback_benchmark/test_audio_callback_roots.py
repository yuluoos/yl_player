import unittest


class AudioCallbackRootTests(unittest.TestCase):
    def test_marker_requires_exact_phase_process_and_completed_delivery(self):
        from run_audio_callback_roots import validate_marker
        marker = dict(phase='played', pid=42, delivered=200, alive=200,
                      firstAddress='0x1234')
        validate_marker(marker, 'played', 42)
        for change in (dict(pid=43), dict(phase='reset'), dict(delivered=199),
                       dict(alive=201), dict(firstAddress='arbitrary'),
                       dict(alive=0), dict(pid=True)):
            with self.assertRaises(ValueError):
                validate_marker(dict(marker, **change), 'played', 42)
        validate_marker(dict(phase='disposed', pid=42, delivered=200, alive=0,
                             firstAddress=None), 'disposed', 42)

    def test_failed_probe_retains_every_planned_slot_and_cannot_pass(self):
        from run_audio_callback_roots import planned_records, complete
        records = planned_records()
        self.assertEqual(len(records), 4)
        self.assertEqual(sum(len(r['probes']) for r in records), 16)
        self.assertFalse(complete(records, 0))
        for r in records:
            r['status'] = 'observed'
            for p in r['probes']:
                p['status'] = 'captured'
        self.assertTrue(complete(records, 0))
        records[1]['probes'][0]['status'] = 'timeout'
        self.assertFalse(complete(records, 0))
        self.assertFalse(complete(records, -6))

    def test_capture_validation_rejects_wrong_pid_empty_tree_and_wrong_address(self):
        from run_audio_callback_roots import usable_capture
        self.assertFalse(usable_capture('heap', 'Process: audio_callback_probe [43]', 42, None))
        self.assertFalse(usable_capture('dispatch-stacks',
            'malloc_history Report Version:  2.0\nProcess: audio_callback_probe [42]\nCall graph:\n\nBinary Images:\n', 42, None))
        self.assertFalse(usable_capture('marker-roots',
            'Tracing: <DeliveredCallbackMarker 0x9999> [16]\nFound 1 roots referencing:', 42, '0x1234'))
        self.assertTrue(usable_capture('marker-roots',
            'Tracing: <DeliveredCallbackMarker 0x1234> [16]\nFound 1 roots referencing:', 42, '0x1234'))


if __name__ == '__main__':
    unittest.main()
