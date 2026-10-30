import json, pathlib, resource, signal, subprocess, time
directory = pathlib.Path('/private/tmp/yl-packet-evidence/media/packets')
command = ['/usr/sbin/tcpdump', '-i', 'en0', '-nn', '-s', '0', '-U', '-w', '/private/tmp/yl-packet-evidence/media/packets/capture.pcap', 'tcp and host 192.168.50.196 and port 56773']
maximum = 180
maximum_bytes = 67108864
# The kernel enforces the file bound even between polling iterations. A record
# cut at the limit remains failed/truncated evidence, never a successful capture.
resource.setrlimit(resource.RLIMIT_FSIZE, (maximum_bytes, maximum_bytes))
started = time.monotonic()
reason = 'tcpdump-exited'
with (directory / 'tcpdump.log').open('w') as log:
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=log,
                               env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LC_ALL':'C'})
    try:
        while process.poll() is None:
            if not (directory / 'ready').exists() and 'listening on ' in (directory / 'tcpdump.log').read_text():
                (directory / 'ready').write_text('ready\n')
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
            durationSeconds=time.monotonic()-started))+'\n')
