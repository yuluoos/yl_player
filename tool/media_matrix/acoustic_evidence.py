"""Locate displayed MP4 markers on the independently captured microphone sample clock."""
import math
import re
from typing import NamedTuple, Optional

COLORS = ((255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255))
PROTOCOL = 'builtin-acoustic-marker-v1'
MEDIA = '3be1bec9f93c98fe29bc9d725dc030fac22781acd792a5142ab6772bc8413e96'


class Window(NamedTuple):
    host_us: int
    sample: int
    marker: Optional[int]
    rate: int


def require(value, reason):
    if not value:
        raise ValueError(reason)


def marker(bands):
    require(isinstance(bands, list) and len(bands) == 8 and all(
        type(x) in (int, float) and math.isfinite(x) and 0 <= x <= 1 for x in bands),
        'invalid_microphone_bands')
    scores = [bands[i] + bands[i + 1] for i in range(0, 8, 2)]
    best = max(scores)
    if best > 0.28 and best > 3 * sorted(scores)[-2]:
        return scores.index(best)
    return None


def read_windows(records):
    windows = []
    for record in records:
        if 'bands' not in record:
            continue
        rate, frames = record['rate'], record['frames']
        sample, host = record['sample'], record['hostUs']
        require(rate in (44100, 48000) and frames == round(rate * 0.04) and
                type(sample) is int and type(host) is int, 'invalid_acoustic_clock')
        window = Window(host + 20000, sample + frames // 2, marker(record['bands']), rate)
        if windows:
            old = windows[-1]
            elapsed_us = (window.sample - old.sample) * 1e6 / rate
            require(rate == old.rate and 39000 <= elapsed_us <= 100000 and
                    abs(window.host_us - old.host_us - elapsed_us) <= 5000, 'discontinuous_acoustic_clock')
        windows.append(window)
    return windows


def transition_sample(windows, first):
    anchors = []
    # Two observed windows of each tone straddle the actual one-second boundary.
    # A single window can contain both tones at the transition.
    for i in range(1, len(windows) - 2):
        if windows[i-1].marker != first or windows[i].marker != first:
            continue
        j = i + 1
        if windows[j].marker is None:
            j += 1
        if (j + 1 < len(windows) and windows[j].marker == windows[j+1].marker == first+1
                and windows[j].host_us - windows[i].host_us <= 110000):
            anchors.append((windows[i].sample + windows[j].sample) / 2)
    require(len(anchors) == 1, 'acoustic_transition_unverified')
    return anchors[0]


def inspect(plan, row):
    spec = plan['acoustic']
    require(plan['platform'] == 'macos' and len(plan['planned']) == 1 and
            (row['caseId'], row['transport'], row['mediaHash']) == ('mp4-avc-aac', 'file', MEDIA)
            and spec['protocol'] == PROTOCOL, 'wrong_acoustic_scope')
    capture = row['acoustic']
    require(re.fullmatch('[0-9a-f]{64}', spec['helperSha256']) and
            capture['helperSha256'] == spec['helperSha256'] and
            capture['runId'] == plan['runId'] == row['runId'] and
            capture['sessionId'] == row['publicSessionId'], 'acoustic_identity_mismatch')
    records = capture['records']
    require(all(r['runId'] == plan['runId'] and 'error' not in r for r in records)
            and sum(r.get('ready') is True and r.get('builtinInput') is True and
                    r.get('builtinOutput') is True for r in records) == 1
            and records[-1].get('ended') is True, 'acoustic_capture_incomplete')
    windows = read_windows(records)
    before = [w for w in windows if w.host_us < capture['launchUs']]
    require(len(before) >= 6 and all(w.marker is None for w in before[-6:]), 'acoustic_silence_control_failed')
    measurements = []
    previous_end = capture['launchUs']
    require(len(row['phases']) == len(plan['phases']), 'acoustic_phase_count')
    for phase, expected in zip(row['phases'], plan['phases']):
        pixels = phase['pixels']
        require(pixels[0]['hostTimeUs'] > previous_end, 'overlapping_acoustic_phases')
        previous_end = pixels[-1]['hostTimeUs']
        heard = [w for w in windows if pixels[0]['hostTimeUs'] <= w.host_us <= pixels[-1]['hostTimeUs']]
        first = expected['markers'][0]
        anchor = transition_sample(heard, first)
        for target in expected['markers']:
            clocks = []
            for px in pixels:
                if px.get('format') != 'rgb8' or any(abs(a-b) > 24 for a,b in zip(px['value'], COLORS[target])):
                    continue
                window = min(heard, key=lambda w: abs(w.host_us - px['hostTimeUs']))
                if window.marker != target or abs(window.host_us - px['hostTimeUs']) > 40000:
                    continue
                pos = round((first+1)*1e6 + (window.sample-anchor)*1e6/window.rate)
                if target*1e6 <= pos < (target+1)*1e6:
                    clocks.append(pos)
            require(len(clocks) >= 2 and max(clocks)-min(clocks) >= 100000, 'acoustic_pixel_pair_missing')
            measurements.append(dict(phase=phase['phase'], marker=target, firstUs=min(clocks), lastUs=max(clocks), pairs=len(clocks)))
    return measurements
