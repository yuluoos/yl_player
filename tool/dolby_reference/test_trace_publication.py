"""CLI publication contract, with real files and kernel-enforced write failure.

The completed metadata producer is replaced at the publication boundary; media
parsing/decoding have separate integration suites. File operations stay real.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
PAYLOAD = b'{"packet_index":0}\n' * 100
DRIVER = r'''
import importlib, io, json, os, signal, resource, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
module = importlib.import_module(sys.argv[2])
scenario, destination = sys.argv[3], Path(sys.argv[4])
payload = b'{"packet_index":0}\n' * 100
os.umask(0)
def producer(*args, **kwargs):
    kwargs['trace_sink'].write(payload)
    if scenario == 'producer_failure':
        raise ValueError('private producer detail')
    return {'trace_sha256': __import__('hashlib').sha256(payload).hexdigest()}
setattr(module, 'decode' if module.__name__ == 'decoded_alignment' else 'inspect', producer)
if scenario == 'write_failure':
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_FSIZE, (512, 512))
if scenario == 'link_race':
    original_link = os.link
    def race(source, target):
        destination.write_bytes(b'competing evidence')
        original_link(source, target)
    os.link = race
if scenario in ('observe_write', 'flush_failure'):
    class Observed:
        def __init__(self, file): self.file = file
        def __enter__(self): return self
        def __exit__(self, *args):
            try:
                if args[0] is None: self.flush()
            finally:
                self.file.__exit__(*args)
        def __getattr__(self, key): return getattr(self.file, key)
        def write(self, data):
            if scenario == 'observe_write':
                assert not destination.exists(), 'final trace visible before write completion'
            return self.file.write(data)
        def flush(self):
            self.file.flush()
            if scenario == 'flush_failure': raise OSError('private flush failure')
    original_fdopen, original_open = os.fdopen, io.open
    os.fdopen = lambda *a, **k: Observed(original_fdopen(*a, **k))
    io.open = lambda *a, **k: Observed(original_open(*a, **k))
sys.argv = ['probe', '--media', 'unused', '--sha256', 'unused', '--inspector', 'unused', '--trace', str(destination)]
if module.__name__ == 'decoded_alignment': sys.argv += ['--decoder', 'unused']
sys.exit(module.main())
'''


class TracePublicationTests(unittest.TestCase):
    def run_cli(self, module, scenario, destination):
        return subprocess.run([sys.executable, '-B', '-c', DRIVER, str(ROOT), module,
                               scenario, str(destination)], capture_output=True, timeout=10)

    def each(self, scenario, verify):
        for module in ('stream_inventory', 'decoded_alignment'):
            with self.subTest(module=module), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                destination = root/'trace.jsonl'
                verify(root, destination, lambda: self.run_cli(module, scenario, destination))

    def assert_failure(self, result):
        self.assertEqual(result.returncode, 2, result.stderr.decode())
        self.assertTrue(json.loads(result.stdout)['code'].startswith('dolby.'))
        self.assertNotIn(b'private', result.stdout + result.stderr)

    def test_complete_trace_has_private_permissions_independent_of_umask(self):
        def verify(root, path, run):
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(path.read_bytes(), PAYLOAD)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(set(root.iterdir()), {path})
        self.each('success', verify)

    def test_final_path_is_absent_until_complete_write(self):
        def verify(root, path, run):
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(path.read_bytes(), PAYLOAD)
        self.each('observe_write', verify)

    def test_kernel_write_failure_leaves_no_partial_trace_or_scratch(self):
        def verify(root, path, run):
            self.assert_failure(run())
            self.assertEqual(list(root.iterdir()), [])
        self.each('write_failure', verify)

    def test_flush_failure_leaves_no_trace_or_scratch(self):
        def verify(root, path, run):
            self.assert_failure(run())
            self.assertEqual(list(root.iterdir()), [])
        self.each('flush_failure', verify)

    def test_existing_trace_is_never_replaced(self):
        def verify(root, path, run):
            path.write_bytes(b'existing evidence')
            self.assert_failure(run())
            self.assertEqual(path.read_bytes(), b'existing evidence')
            self.assertEqual(set(root.iterdir()), {path})
        self.each('success', verify)

    def test_concurrent_destination_creation_is_not_replaced_or_removed(self):
        def verify(root, path, run):
            self.assert_failure(run())
            self.assertEqual(path.read_bytes(), b'competing evidence')
            self.assertEqual(set(root.iterdir()), {path})
        self.each('link_race', verify)

    def test_symlinks_are_refused_including_dangling_links(self):
        def verify(root, path, run):
            target = root/'target'
            for exists in (False, True):
                if exists: target.write_bytes(b'original')
                path.symlink_to(target)
                self.assert_failure(run())
                self.assertTrue(path.is_symlink())
                self.assertEqual(target.exists(), exists)
                if exists: self.assertEqual(target.read_bytes(), b'original')
                path.unlink()
            self.assertEqual(set(root.iterdir()), {target})
        self.each('success', verify)

    def test_producer_failure_never_publishes_buffered_trace(self):
        def verify(root, path, run):
            self.assert_failure(run())
            self.assertEqual(list(root.iterdir()), [])
        self.each('producer_failure', verify)


if __name__ == '__main__': unittest.main()
