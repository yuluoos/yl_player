"""Offline reviewer reproducer: no subprocesses, network listeners or device operations."""
import json
import plistlib
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(sys.argv[1]) / 'tool/playback_network'))
import abr_accesslog

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    products = root / 'products'
    app = products / 'Runner.app'
    app.mkdir(parents=True)
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Runner', 'CFBundleIdentifier': 'owned.bundle'}))
    (app / 'Runner').write_bytes(b'owned mock executable')
    (products / 'probe.xctestrun').write_bytes(plistlib.dumps({
        'RunnerTests': {'TestHostPath': '__TESTROOT__/Runner.app/Runner'}}))
    args = SimpleNamespace(directory=root / 'capture', products=products, device=None,
        physical_device='00008140-000C49CC3493001C', owned_host='192.168.50.196',
        profiles=Path('unused'), profile='owned')
    server = Mock(server_port=1234)
    process = Mock()
    process.poll.return_value = 0
    with patch('abr_accesslog.create', return_value={}), \
            patch('abr_accesslog.load_profiles', return_value={'owned': SimpleNamespace(sha256='mock')}), \
            patch('abr_accesslog.make_server', return_value=server), \
            patch('abr_accesslog.subprocess.Popen', return_value=process), \
            patch('abr_accesslog.wait_for_native', return_value=0), \
            patch('abr_accesslog.abr_device.collect'), \
            patch('abr_accesslog.abr_device.cleanup', return_value=True), \
            patch('abr_accesslog.read_rows', return_value=[None, None]):
        try:
            abr_accesslog.run(args)
        except Exception as error:
            print('raised:', type(error).__name__)
    receipt = json.loads((args.directory / 'receipt.json').read_text())
    print(json.dumps({key: receipt.get(key) for key in [
        'passed', 'errors', 'exitCode', 'observation', 'continuityObservation']}, sort_keys=True))
