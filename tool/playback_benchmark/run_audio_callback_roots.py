"""Short native callback ownership diagnostic; never a performance baseline."""
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time

PHASES = ('configured', 'played', 'reset', 'disposed')
OBSERVERS = ('heap', 'marker-roots', 'marker-history', 'dispatch-stacks')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def raw_us():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW) // 1000


def validate_marker(marker, phase, pid):
    if marker.get('phase') != phase or type(marker.get('pid')) is not int or marker['pid'] != pid:
        raise ValueError('Unexpected phase or owned process')
    if type(marker.get('delivered')) is not int or marker['delivered'] != (0 if phase == 'configured' else 200):
        raise ValueError('Playback callbacks incomplete')
    alive = marker.get('alive')
    if type(alive) is not int or not 0 <= alive <= 200:
        raise ValueError('Invalid live marker count')
    address = marker.get('firstAddress')
    if (alive == 0 and address is not None) or (alive > 0 and
            (not isinstance(address, str) or not re.fullmatch(r'0x[1-9a-f][0-9a-f]*', address))):
        raise ValueError('Invalid live marker address')


def planned_records():
    return [dict(phase=phase, status='not_observed', probes=[
        dict(tool=tool, status='not_observed') for tool in OBSERVERS]) for phase in PHASES]


def complete(records, exit_code):
    return exit_code == 0 and len(records) == len(PHASES) and all(
        r['status'] == 'observed' and len(r['probes']) == len(OBSERVERS) and all(
            p['status'] in ('captured', 'not_applicable') for p in r['probes']) for r in records)


def usable_capture(tool, text, pid, address):
    identity = re.search(r'^Process: +audio_callback_probe \[' + str(pid) + r'\] *$', text, re.M)
    if tool == 'heap':
        return bool(identity and re.search(r'^\s*\d+\s+\d+\s+[\d.]+\s+dispatch_source_t\s', text, re.M))
    if tool == 'marker-roots':
        return bool(f'Tracing: <DeliveredCallbackMarker {address}>' in text and
                    re.search(r'Found [1-9][0-9]* roots referencing:', text))
    if tool == 'marker-history':
        return bool(text.startswith('malloc_history Report Version:  2.0\n') and
                    f'ALLOC {address}-' in text and 'DeliveredCallbackMarker.__allocating_init' in text)
    if tool == 'dispatch-stacks':
        graph = text.split('Call graph:', 1)[-1].split('Binary Images:', 1)[0]
        return bool(identity and re.search(r'^\s*\d+\s+', graph, re.M))
    return False


def collect(output):
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).with_name('audio_callback_probe.swift')
    binary = output / 'audio_callback_probe'
    sources = [source, Path(__file__).resolve(), Path(__file__).with_name('test_audio_callback_roots.py')]
    for path in sources:
        (output / path.name).write_bytes(path.read_bytes())
    build = ['xcrun', 'swiftc', '-g', '-module-cache-path', str(output / 'module-cache'),
             str(source), '-o', str(binary)]
    with (output / 'build.log').open('w') as stream:
        subprocess.run(build, stdout=stream, stderr=stream, check=True, timeout=120)
    environment = dict(MallocStackLogging='full', MallocStackLoggingNoCompact='1')
    protocol = dict(version=3, purpose='native callback roots; not performance admission',
        buffers=200, frames=1024, sampleRate=48000, channels=2, interleaved=False,
        completionType='dataPlayedBack', phases=PHASES, observers=OBSERVERS,
        probeTimeoutSeconds=8, markerTimeoutSeconds=20, buildCommand=build,
        sources={p.name: digest(p) for p in sources}, binarySha256=digest(binary),
        environment=environment,
        limitations=['Standalone graph mirrors system output, not the actual Flutter pipeline',
                    'Instrumented short diagnosis, not long-term continuity or performance',
                    'Engine and player remain alive after detach; no destruction assertion'])
    (output / 'protocol.json').write_text(json.dumps(protocol, indent=2) + '\n')
    result = dict(startedUs=raw_us(), protocolSha256=digest(output / 'protocol.json'),
                  records=planned_records(), complete=False)
    def persist():
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    persist()
    with (output / 'stderr.txt').open('w') as stderr:
        process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=stderr, text=True, env=dict(os.environ, **environment))
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            for record in result['records']:
                if not selector.select(20):
                    raise TimeoutError('Missing phase ' + record['phase'])
                line = process.stdout.readline()
                with (output / 'markers.jsonl').open('a') as stream:
                    stream.write(line)
                marker = json.loads(line)
                record['marker'] = marker
                validate_marker(marker, record['phase'], process.pid)
                record.update(status='observed', startedUs=raw_us())
                for probe in record['probes']:
                    tool = probe['tool']
                    probe['startedUs'] = raw_us()
                    address = marker['firstAddress']
                    if tool in ('marker-roots', 'marker-history') and address is None:
                        probe.update(status='not_applicable', reason='No live marker', endedUs=raw_us())
                        continue
                    actual = subprocess.check_output(['/bin/ps', '-p', str(process.pid), '-o', 'comm='],
                                                     text=True, timeout=2).strip()
                    if actual != str(binary):
                        raise ValueError('Owned executable mismatch')
                    commands = {
                        'heap': ['/usr/bin/heap', '--noContent', str(process.pid)],
                        'marker-roots': ['/usr/bin/leaks', '--noContent', '--traceTree=' + str(address), str(process.pid)],
                        'marker-history': ['/usr/bin/malloc_history', str(process.pid), '-fullStacks', str(address)],
                        'dispatch-stacks': ['/usr/bin/malloc_history', str(process.pid), '-callTree',
                                            '-noContent', '-invert', '-ignoreThreads', 'dispatch_source_t']}
                    command = commands[tool]
                    probe['command'] = command
                    path = output / (record['phase'] + '-' + tool + '.txt')
                    try:
                        with path.open('w') as stream:
                            child = subprocess.run(command, stdout=stream, stderr=stream, timeout=8)
                        probe['exitCode'] = child.returncode
                        probe['status'] = 'captured' if child.returncode == 0 and usable_capture(
                            tool, path.read_text(), process.pid, address) else 'failed'
                    except subprocess.TimeoutExpired:
                        probe['status'] = 'timeout'
                    finally:
                        probe.update(endedUs=raw_us(), raw=dict(file=path.name, sha256=digest(path), bytes=path.stat().st_size))
                        persist()
                record['endedUs'] = raw_us()
                persist()
                process.stdin.write('continue\n')
                process.stdin.flush()
            result['exitCode'] = process.wait(timeout=5)
            result['complete'] = complete(result['records'], result['exitCode'])
        except (ValueError, OSError, TimeoutError, subprocess.SubprocessError) as error:
            result['error'] = repr(error)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            selector.close()
            process.stdin.close()
            process.stdout.close()
            result.update(endedUs=raw_us(), processExited=True, exitCode=process.returncode)
            persist()
    return result['complete']


if __name__ == '__main__':
    sys.exit(0 if collect(Path(sys.argv[1])) else 1)
