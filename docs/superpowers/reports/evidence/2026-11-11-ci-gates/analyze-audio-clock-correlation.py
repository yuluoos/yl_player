"""Recompute the CI #124/#126 audio row / CoreAudio log associations.

Run from any directory; --check compares instead of writing derived JSON.
Inputs are immutable evidence next to this script. This is an offline analysis,
not a replacement test gate. See audio-clock-correlation-provenance.json.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import gzip
import json
from pathlib import Path
import re


def read(path):
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == ".gz" else raw)


def epoch(timestamp):
    return datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()


def correlate(root, run):
    events = read(root / (run + "-audio-clock-events.json.gz"))
    attachments = read(root / (run + "-audio-clock-attachments.json.gz"))
    # Check that newly joined timestamp/row data reproduce the older matrix.
    original = read(root / (run + "-macos-audio-matrix.json.gz"))
    canonical = lambda rows: sorted(json.dumps(row, sort_keys=True) for row in rows)
    assert canonical(original) == canonical(item["row"] for item in attachments)
    previous = attachments[0]["attachment"]["timestamp"] - 3
    rows = []
    for item in attachments:
        attachment, row = item["attachment"], item["row"]
        end = attachment["timestamp"]
        starts = [event for event in events
                  if previous < epoch(event["timestamp"]) < end
                  and event["processImagePath"].endswith("/yl_player_example")
                  and "Engine@" in event["eventMessage"]
                  and ": start," in event["eventMessage"]]
        # The initial lookback includes the preceding test. After the first
        # attachment there is exactly one engine start per archived row.
        assert starts and (not rows or len(starts) == 1), (run, attachment, len(starts))
        start = starts[-1]
        core = [event for event in events
                if epoch(start["timestamp"]) <= epoch(event["timestamp"]) <= end
                and event["processImagePath"].endswith("/coreaudiod")]
        resets = [event for event in core
                  if "Re-anchoring IO timeline" in event["eventMessage"]]
        differences = Counter()
        for event in resets:
            match = re.search(r"sample diff: ([\d.-]+)", event["eventMessage"])
            differences[match[1] if match else "initial-host-out-of-bounds"] += 1
        name = "raw" if row.get("kind") else "candidate" if row["candidate"] else "legacy"
        name += "-" + str(row["buffers"])
        if row.get("starvation"):
            name += "-starvation"
        if row.get("pausedEOF"):
            name += "-paused"
        rows.append({
            "row": name,
            "attachment": attachment,
            "engineStart": start,
            "estimatedLoopStartUtc": datetime.fromtimestamp(
                end - row["elapsedSeconds"], timezone.utc).isoformat(),
            "expectedFrames": row["buffers"] * 1024,
            "marker": row["marker"],
            "capture": row.get("capture"),
            "clockResetCount": len(resets),
            "clockResetSampleDiffCounts": dict(differences),
            "outOfBoundsCount": sum("Out of bounds host time" in e["eventMessage"] for e in core),
            "deadlineBeforeStartCount": sum("Deadline is prior" in e["eventMessage"] for e in core),
            "overloadReports": sum("Audio IO Overload thread" in e["eventMessage"] for e in core),
        })
        previous = end
    return {
        "run": run,
        "devicesAndConfigurations": read(root / (run + "-macos-summary.json.gz"))["devicesAndConfigurations"],
        "method": "Associate each row with the latest app engine start before its attachment. The first row uses a three-second lookback; every later row has exactly one start after the preceding attachment. Count coreaudiod events from that start through this attachment. Loop start estimated by attachment timestamp minus elapsedSeconds is approximate and is not a tap host-time anchor. Counts refer only to the selected exported log events.",
        "rows": rows,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    for run in ("ci124", "ci126"):
        result = correlate(root, run)
        output = root / (run + "-audio-clock-correlations.json")
        if args.check:
            assert read(output) == result, output
        else:
            output.write_text(json.dumps(result, indent=2) + "\n")
        print(run, len(result["rows"]), "rows verified" if args.check else "rows written")
