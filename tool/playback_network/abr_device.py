"""Bounded file export and identity-checked cleanup for the owned XCTest host."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
from urllib.parse import unquote, urlparse

FILES = ('process.json', 'rows.jsonl', 'frame-samples.jsonl',
         'automatic-events.json', 'recovery-attempt.json', 'policy-decisions.jsonl')


def invoke(args, out, name):
    try:
        result = subprocess.run(['xcrun', 'devicectl', *args], capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired as error:
        def text(value):
            return value.decode(errors='replace') if isinstance(value, bytes) else (value or '')
        (out / (name + '.json')).write_text(json.dumps(dict(command=['xcrun', 'devicectl', *args],
            exitCode=None, timedOut=True, output=(text(error.stdout) + text(error.stderr))[-12000:]), indent=2) + '\n')
        raise
    (out / (name + '.json')).write_text(json.dumps(dict(command=['xcrun', 'devicectl', *args],
        exitCode=result.returncode, output=(result.stdout + result.stderr)[-12000:]), indent=2) + '\n')
    result.check_returncode()


def collect(device, bundle, out, token):
    if not re.fullmatch('[a-f0-9]{32}', token): raise ValueError('invalid capture token')
    export = out / 'device-export'
    invoke(['device', 'copy', 'from', '--device', device, '--source', 'tmp/yl-abr-' + token,
            '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
            '--destination', str(export)], out, 'device-export-command')
    for name in FILES:
        matches = list(export.rglob(name))
        if not matches and name not in FILES[:3]: continue
        if len(matches) != 1 or matches[0].is_symlink() or matches[0].stat().st_size > 16*1024*1024:
            raise ValueError('missing or ambiguous device observation')
        shutil.copyfile(matches[0], out / name)


def processes(device):
    # Do not archive details of unrelated device applications.
    with tempfile.TemporaryDirectory() as tmp:
        output = Path(tmp) / 'processes.json'
        subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'processes', '--device', device,
            '--json-output', str(output)], capture_output=True, check=True, timeout=30)
        if output.stat().st_size > 4*1024*1024: raise ValueError('oversized process list')
        return json.loads(output.read_text())['result']['runningProcesses']


def cleanup(device, out, token, executable):
    path = out / 'process.json'
    if not path.exists(): return False
    if path.stat().st_size > 4096: raise ValueError('oversized process proof')
    proof = json.loads(path.read_text())
    if not isinstance(proof, dict): raise ValueError('invalid device process proof')
    pid = proof.get('pid'); binary = proof.get('executable')
    if (proof.get('token') != token or proof.get('deviceKind') != 'physical' or type(pid) is not int or pid <= 1 or
        not isinstance(binary, str) or Path(binary).name != executable or '.app/' not in binary):
        raise ValueError('invalid device process proof')
    def current():
        entries = processes(device)
        if not isinstance(entries, list) or not all(isinstance(p, dict) for p in entries):
            raise ValueError('invalid device process list')
        matches = [p for p in entries if p.get('processIdentifier') == pid]
        if not matches: return 'exited'
        if len(matches) != 1: return 'changed'
        executable_url = matches[0].get('executable')
        if not isinstance(executable_url, str): raise ValueError('invalid executable URL')
        url = urlparse(executable_url)
        return 'owned' if url.scheme == 'file' and not url.netloc and unquote(url.path) == binary else 'changed'
    state = current()
    (out / 'device-process-check.json').write_text(json.dumps(dict(pid=pid, state=state)) + '\n')
    if state != 'owned': return state == 'exited'
    invoke(['device', 'process', 'terminate', '--device', device, '--pid', str(pid)], out, 'device-cleanup-command')
    for _ in range(5):
        state = current()
        if state != 'owned': return state == 'exited'
        time.sleep(.2)
    return False
