"""The optional research overlay must fail closed on a changed source."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('overlay',Path(__file__).with_name('probes')/'apply_cm4_overlay.py')
overlay=importlib.util.module_from_spec(spec);spec.loader.exec_module(overlay)

def sha(s):return hashlib.sha256(s.encode()).hexdigest()

class OverlayTests(unittest.TestCase):
    def test_exact_patch_and_second_application_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'source';p.write_text('old')
            m={'source':{'before':sha('old'),'after':sha('new'),'edits':[['old','new']]}}
            self.assertEqual(overlay.apply(d,m),{'source':sha('new')})
            with self.assertRaises(ValueError):overlay.apply(d,m)

    def test_all_sources_and_results_checked_before_any_write(self):
        for change in ('source','before','after','edits'):
            with tempfile.TemporaryDirectory() as d:
                p=Path(d);(p/'a').write_text('old');(p/'b').write_text('old')
                template={'before':sha('old'),'after':sha('new'),'edits':[['old','new']]}
                m={'a':copy.deepcopy(template),'b':copy.deepcopy(template)}
                if change=='source':(p/'b').write_text('changed')
                elif change=='edits':m['b'][change]=[['absent','new']]
                else:m['b'][change]='0'*64
                with self.assertRaises(ValueError):overlay.apply(d,m)
                self.assertEqual((p/'a').read_text(),'old')

    def test_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ('../outside','/outside'):
                with self.assertRaises(ValueError):overlay.apply(d,{name:{}})
