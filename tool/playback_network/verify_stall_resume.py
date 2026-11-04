"""Verify same-session playback across the owned 25-second DASH outage on iOS."""
import json
import sys
from pathlib import Path

from abr_accesslog import read_rows


def verify(directory):
    receipt = json.loads((directory / 'receipt.json').read_text())
    rows = read_rows(directory / 'rows.jsonl')
    requests = read_rows(directory / 'requests.jsonl')
    frames = [row for row in read_rows(directory / 'frame-samples.jsonl') if row['frames']]
    last = rows[-1]
    if not (receipt['deviceKind'] == 'physical' and receipt['exitCode'] == 0
            and receipt['ownedProcessExited'] and receipt['binaryIdentityUnchanged']
            and last['completed'] and last['position'] >= 119.5
            and all(row['sessionId'] == last['sessionId'] and row['productionRecovery']
                    and row['productionCommand'] == 'none' and row['hostFailureCount'] == 0
                    for row in rows)):
        raise ValueError('same-session physical playback did not complete')

    if not (requests and all(row['profile'] == 'downshift-and-25s-body-stall-v1'
            and row['phaseBoundariesMs'] == [0, 10000, 15000, 50000, 75000]
            and row['phaseBytesWritten'][3] == 0 for row in requests)
            and any(row['phaseBytesWritten'][4] > 0 for row in requests)):
        raise ValueError('missing 25-second outage and restored media delivery')

    # Convert the server phase boundaries into the range of possible player times
    # measured by the existing HEAD clock-alignment probe.
    clock = last['clockAlignment']
    start = 50 + (clock['beforeUs'] - clock['serverUs']) / 1e6
    end = 75 + (clock['afterUs'] - clock['serverUs']) / 1e6
    for before, after in zip(frames, frames[1:]):
        if not (start <= before['elapsed'] <= end <= after['elapsed']
                and after['elapsed'] - before['elapsed'] > 15):
            continue
        previous_pts = before['framePresentationTimes'][-1]
        resumed_pts = after['framePresentationTimes'][0]
        # The owned programme runs at 24 fps. Allow one timestamp tick of rounding.
        if (before['generation'] == after['generation']
                and 0 < resumed_pts - previous_pts <= 1 / 24 + 0.000001):
            return dict(lastFrameSeconds=previous_pts, resumedFrameSeconds=resumed_pts,
                        gapSeconds=after['elapsed'] - before['elapsed'], endSeconds=last['position'])
    raise ValueError('missing consecutive frames across the read timeout')


if __name__ == '__main__':
    try:
        print(json.dumps(verify(Path(sys.argv[1])), indent=2))
    except ValueError as error:
        sys.exit(str(error))
