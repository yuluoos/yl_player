"""Opt-in macOS fixture capture using a separately authorized microphone helper."""
from contextlib import ExitStack, contextmanager
import json
import subprocess
import sys
import time

from bound_artifacts import sha_file


@contextmanager
def microphone(app, plan, directory):
    if app is None:
        yield None
        return

    app = app.resolve()
    binary = app / 'Contents/MacOS/Marker'
    output = directory / 'acoustic.jsonl'
    stop = output.with_suffix('.jsonl.stop')
    run_id = plan['runId']
    before = plan['acoustic']['helperSha256']
    # Bound microphone use even if the collector is killed without running finally.
    deadline_command = [sys.executable, '-c',
        'import pathlib,sys,time; time.sleep(35); pathlib.Path(sys.argv[1]).touch()', str(stop)]
    with ExitStack() as cleanup:
        watchdog = cleanup.enter_context(subprocess.Popen(deadline_command, start_new_session=True))
        cleanup.callback(watchdog.terminate)
        launch = subprocess.Popen(['open', '-n', '-W', str(app), '--args', 'capture', run_id, str(output)])
        cleanup.callback(launch.wait, timeout=15)
        cleanup.callback(stop.touch)
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and launch.poll() is None:
            if output.exists() and '"ready":true' in output.read_text():
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Acoustic helper did not start. Check microphone permission and built-in routes.')
        time.sleep(0.5)  # Silence control before launching the player.
        capture = dict(runId=run_id, helperSha256=before, launchUs=time.monotonic_ns() // 1000)
        yield capture
    if sha_file(binary) != before:
        raise RuntimeError('Acoustic helper changed during collection.')
    capture['records'] = [json.loads(line) for line in output.read_text().splitlines()]
