from pathlib import Path
p=Path('tool/playback_network/test_abr_accesslog.py');s=p.read_text();start=s.index('    def test_production_recovery_requires_real_public_install_and_high_frames');end=s.index('    def test_candidate_preparation',start)
old=s[start:end];new=old.replace('test_production_recovery_requires_real_public_install_and_high_frames','test_required_production_install_rejects_natural_or_cancelled_only_recovery')
new=new[:new.index('        result =')]+'''        self.assertEqual(abr_accesslog.summarize_production_recovery(rows, frames, require_install=True)['installed'],1)
        for events in [[], [dict(outcome='cancelled', elapsedAfter=20, itemChanged=False)]]:
            rr=copy.deepcopy(rows);rr[-1]['automaticEvents']=events
            self.assertFalse(abr_accesslog.summarize_production_recovery(rr,frames)['triggerExercised'])
            with self.subTest(events=events),self.assertRaises(ValueError):
                abr_accesslog.summarize_production_recovery(rr,frames,require_install=True)
        for invalid in [1, 'yes', None]:
            with self.subTest(invalid=invalid),self.assertRaises(ValueError):
                abr_accesslog.summarize_production_recovery(rows,frames,require_install=invalid)

'''
s=s[:end]+new+s[end:]
needle="        self.assertFalse(abr_accesslog.production_recovery(SimpleNamespace()))"
s=s.replace(needle,needle+'''
        self.assertTrue(abr_accesslog.production_recovery(SimpleNamespace(**values,require_production_install=True)))
        for changes in [dict(require_production_install=1),dict(require_production_install=True,production_recovery=False),
                        dict(require_production_install=True,production_command='load-prepared')]:
            with self.subTest(changes=changes),self.assertRaises(ValueError):
                abr_accesslog.production_recovery(SimpleNamespace(**dict(values,**changes)))''')
p.write_text(s)
