"""Bounded, explicitly authorized macOS capture of one owned TCP service."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import time


def worker_source(command, directory, max_seconds, max_bytes=64*1024*1024):
    """The privileged worker has fixed argv, time/size bounds and no input commands."""
    return '''import json, pathlib, resource, signal, subprocess, time
directory = pathlib.Path(DIRECTORY)
command = COMMAND
maximum = MAXIMUM
maximum_bytes = MAXIMUM_BYTES
# The kernel enforces the file bound even between polling iterations. A record
# cut at the limit remains failed/truncated evidence, never a successful capture.
resource.setrlimit(resource.RLIMIT_FSIZE, (maximum_bytes, maximum_bytes))
# macOS administrator authorization blocks SIGINT in descendants. Restore the
# stop signal before tcpdump inherits the mask, so it can flush and print stats.
signal.pthread_sigmask(signal.SIG_UNBLOCK, [signal.SIGINT])
started = time.monotonic()
reason = 'tcpdump-exited'
with (directory / 'tcpdump.log').open('w') as log:
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=log,
                               env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LC_ALL':'C'})
    try:
        while process.poll() is None:
            if not (directory / 'ready').exists() and 'listening on ' in (directory / 'tcpdump.log').read_text():
                (directory / 'ready').write_text('ready\\n')
            if (directory / 'stop').exists():
                reason = 'stop-requested'; break
            if time.monotonic() - started >= maximum:
                reason = 'deadline'; break
            pcap = directory / 'capture.pcap'
            if pcap.exists() and pcap.stat().st_size >= maximum_bytes:
                reason = 'size-limit'; break
            time.sleep(.2)
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
        try:
            code = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); code = process.wait(); reason = 'forced-stop'
        pcap = directory / 'capture.pcap'
        if pcap.exists() and pcap.stat().st_size >= maximum_bytes: reason = 'size-limit'
        (directory / 'done.json').write_text(json.dumps(dict(exitCode=code, reason=reason,
            durationSeconds=time.monotonic()-started))+'\\n')
'''.replace('DIRECTORY', repr(str(directory))).replace('COMMAND', repr(command)).replace('MAXIMUM_BYTES', repr(max_bytes)).replace('MAXIMUM', repr(max_seconds))


class PacketCapture:
    def __init__(self, directory, interface, host, port):
        self.directory = Path(directory).resolve()
        self.directory.mkdir()
        self.command = ['/usr/sbin/tcpdump', '-i', interface, '-nn', '-s', '0', '-U',
                        '-w', str(self.directory/'capture.pcap'),
                        f'tcp and host {host} and port {port}']
        (self.directory/'command.json').write_text(json.dumps(self.command, indent=2)+'\n')
        self.worker = self.directory/'capture-root.py'
        self.worker.write_text(worker_source(self.command, self.directory, 180))
        self.process = None
        self.log = None

    def start(self):
        # macOS owns the authentication UI; never request or handle a password.
        script = self.directory/'authorize.applescript'
        script.write_text('on run argv\n  do shell script (item 1 of argv) with administrator privileges\nend run\n')
        self.log = (self.directory/'authorization.log').open('w')
        command = shlex.join(['/usr/bin/python3', '-I', str(self.worker)])
        self.process = subprocess.Popen(['/usr/bin/osascript', str(script), command],
                                        stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic()+120
        while time.monotonic()<deadline:
            if (self.directory/'ready').exists(): return
            if self.process.poll() is not None:
                raise ValueError('packet capture authorization or startup failed')
            time.sleep(.2)
        raise ValueError('packet capture authorization timed out')

    def stop(self):
        (self.directory/'stop').touch()
        if self.process is not None:
            try: self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.terminate(); self.process.wait(timeout=5)
        if self.log is not None: self.log.close()
        done = self.directory/'done.json'
        if not done.exists():
            return dict(complete=False, reason='capture-not-started', packetCapturePerformed=False)
        result = json.loads(done.read_text())
        log = (self.directory/'tcpdump.log').read_text()
        for label, pattern in [('packetsCaptured', r'(\d+) packets? captured'),
                               ('kernelDropped', r'(\d+) packets? dropped by kernel')]:
            match = re.search(pattern, log)
            result[label] = int(match.group(1)) if match else None
        result['packetCapturePerformed'] = True
        result['complete'] = (result['exitCode']==0 and result['reason']=='stop-requested'
                              and result['kernelDropped']==0 and result['packetsCaptured'] is not None)
        return result
