import tempfile
import unittest
from pathlib import Path
import consumer_compat as compat

class ConsumerCompatibilityTests(unittest.TestCase):
    def test_prefix_quotes_shell_metacharacters_and_is_idempotent(self):
        script='"$FLUTTER_ROOT/packages/flutter_tools/bin/macos_assemble.sh" embed'
        prefix=compat.prefix(Path("/tmp/owned dir/$(touch NEVER)"))
        updated=compat.patch_script(script,prefix)
        self.assertTrue(updated.startswith("export PATH='/tmp/owned dir/$(touch NEVER)':\"$PATH\"\n"))
        self.assertEqual(compat.patch_script(updated,prefix),updated)
        self.assertTrue(updated.endswith(script))
    def test_rejects_non_flutter_and_conflicting_adapter(self):
        with self.assertRaises(ValueError): compat.patch_script('echo unrelated','prefix')
        with self.assertRaises(ValueError): compat.patch_script('export PATH=other:"$PATH"\nmacos_assemble.sh','new')
    def test_scheme_updates_only_flutter_prepare_action(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'Runner.xcscheme'
            p.write_text('<Scheme><ActionContent scriptText="echo other"/><ActionContent scriptText="macos_assemble.sh prepare"/></Scheme>')
            compat.patch_scheme(p,'export PATH=owned:"$PATH"\n')
            self.assertIn('echo other',p.read_text())
            self.assertIn('PATH=owned:',p.read_text())
            before=p.read_bytes();compat.patch_scheme(p,'export PATH=owned:"$PATH"\n')
            self.assertEqual(before,p.read_bytes())
    def test_missing_action_is_not_silent_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'Runner.xcscheme';p.write_text('<Scheme/>')
            with self.assertRaises(ValueError): compat.patch_scheme(p,'prefix')
