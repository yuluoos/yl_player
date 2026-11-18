"""Recompute per-device PCM losses from archived matrix and render attachments."""
import argparse
from collections import Counter
import gzip
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def identity(value):
    return (value.get("candidate"), value["buffers"], value.get("starvation", False),
            value.get("pausedEOF", False))


def matching_trace(traces, attachment, pcm):
    candidates = [
        item for item in traces
        if item["path"].split("/")[0] == attachment.split("/")[0]
        and item["data"]["path"] == pcm.get("kind", "matrix")
        and identity(item["data"]) == identity(pcm)
    ]
    if len(candidates) == 1:
        return candidates[0]
    # A failed arm can run two controls with the same buffer count.
    tap = pcm["capture"].get("firstCallbackTime", {})
    for_host = []
    for item in candidates:
        trace = item["data"]["trace"]
        first = next((r for r in trace["entries"] if r[5] & trace["preRenderMask"]), None)
        if first and first[1] == tap.get("hostTimeTicks"):
            for_host.append(item)
    if len(for_host) != 1:
        raise ValueError(f"Cannot identify one native trace for {attachment}")
    return for_host[0]


def analyze(attachment, pcm, match):
    candidate, buffers, starvation, paused = identity(pcm)
    expected = buffers * 1024
    missing = expected - pcm["marker"]["frames"]
    row = dict(arm=attachment.split("/")[0].removesuffix("-attachments"), attachment=attachment,
               kind=pcm.get("kind", "matrix"), candidate=candidate, buffers=buffers,
               starvation=starvation, pausedEOF=paused, missingFrames=missing,
               markerErrors=pcm["marker"]["errors"],
               submittedComplete=(pcm["submittedMarker"]["frames"] == expected
                                  and pcm["submittedMarker"]["errors"] == 0))

    trace = match["data"]["trace"]
    entries = trace["entries"]
    pre, post = entries[::2], entries[1::2]
    paired = (len(pre) == len(post) and all(
        before[5] & trace["preRenderMask"] and after[5] & trace["postRenderMask"]
        and before[1:5] == after[1:5] for before, after in zip(pre, post)))
    if not paired:
        raise ValueError(f"Unpaired native render callbacks in {match['path']}")
    scale = trace["timebaseNumer"] / trace["timebaseDenom"] / 1000
    gaps = []
    for prev, following, after in zip(pre, pre[1:], post):
        lower, upper = prev[2] + prev[3], following[2]
        if lower != upper:
            gaps.append((lower, upper, (following[0] - prev[0]) * scale,
                         (after[0] - prev[0]) * scale))
    valid = trace["overflow"] == trace["removeStatus"] == 0
    row.update(traceAttachment=match["path"], completeTrace=valid, renderPairs=len(pre),
               sampleJumps=len(gaps),
               maximumRenderElapsedUs=max(((b[0]-a[0])*scale for a, b in zip(pre, post)), default=0),
               maximumEntryGapUs=max(((b[0]-a[0])*scale for a, b in zip(pre, pre[1:])), default=0))

    if missing:
        capture = pcm["capture"]
        tap = capture.get("firstCallbackTime", {})
        masks = trace["sampleTimeValidMask"] | trace["hostTimeValidMask"]
        aligned = (valid and bool(pre) and trace["sampleRate"] == 48000
                   and all(r[4] & masks == masks for r in pre)
                   and tap.get("sampleTime") == pre[0][2] == 0
                   and tap.get("hostTimeTicks") == pre[0][1] and capture["timestampJumps"] == 0
                   and not starvation and not paused and all(b > a for a, b, *_ in gaps))
        row["timelineProofPrerequisites"] = aligned
        if aligned:
            start = capture["leadingZeros"] - capture["firstMarker"]
            end = start + expected
            intervals = [
                dict(start=a, endExclusive=b, intersectionFrames=max(0, min(b, end) - max(a, start)),
                     entryGapUs=gap, previousRenderElapsedUs=elapsed) for a, b, gap, elapsed in gaps
            ]
            predicted = sum(interval["intersectionFrames"] for interval in intervals)
            row.update(inputStart=start, inputEndExclusive=end, skippedIntervals=intervals,
                       predictedMissingFrames=predicted, exactLossMatch=predicted == missing)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix")
    parser.add_argument("--verify", action="store_true", help="compare to the saved analysis")
    args = parser.parse_args()
    receipt = json.loads((ROOT / (args.prefix + "-comparison.json")).read_bytes())
    with gzip.open(ROOT / (args.prefix + "-attachments.json.gz")) as f:
        items = [item for item in json.load(f) if isinstance(item["data"], dict)]
    traces = [item for item in items if item["data"].get("kind") == "nativeRenderTrace"]
    rows = [analyze(item["path"], item["data"], matching_trace(traces, item["path"], item["data"]))
            for item in items if "marker" in item["data"]]
    if not rows or Counter(r["traceAttachment"] for r in rows) != Counter(t["path"] for t in traces):
        raise ValueError("PCM rows and native traces must pair one-to-one")

    expected = {(c, n, False, False) for c in (True, False) for n in (0, 1, 3, 2000)}
    expected.update((c, 100, True, False) for c in (True, False))
    expected.update((c, 3, False, True) for c in (True, False))
    listed = Counter(f"{arm['label']}-attachments/{p['attachment']}"
                     for arm in receipt["runs"] for p in arm["pcmRows"])
    if Counter(r["attachment"] for r in rows) != listed:
        raise ValueError("Receipt and exported PCM attachments differ")
    pcm_by_path = {item["path"]: item["data"] for item in items if "marker" in item["data"]}
    for arm in receipt["runs"]:
        for pcm in arm["pcmRows"]:
            raw = pcm_by_path[f"{arm['label']}-attachments/{pcm['attachment']}"]
            if any(raw[k] != v for k, v in pcm.items() if k != "attachment"):
                raise ValueError(f"Receipt differs from PCM attachment {pcm['attachment']}")
        summary_path = ROOT / (args.prefix + "-" + arm["label"] + "-summary.json.gz")
        with gzip.open(summary_path) as f:
            summary = json.load(f)
        if any(arm[k] != summary[k] for k in ("passedTests", "failedTests", "skippedTests")):
            raise ValueError(f"Receipt differs from XCTest summary for {arm['label']}")
        selected = [r for r in rows if r["arm"] == arm["label"]]
        cases = [identity(r) for r in selected if r["kind"] == "matrix"]
        if len(cases) != len(expected) or set(cases) != expected:
            raise ValueError(f"Incomplete matrix in {arm['label']}")
        losses = [r for r in selected if r["missingFrames"]]
        exact = sum(bool(r.get("exactLossMatch")) for r in losses)
        print(f"{arm['label']}: {len(selected)} rows, {len(losses)} losses, {exact} exact matches")

    target = ROOT / (args.prefix + "-timeline-analysis.json")
    if args.verify:
        if not all(r["submittedComplete"] and r["completeTrace"] for r in rows):
            raise ValueError("Archived claim requires complete input and complete native traces")
        if any(r.get("exactLossMatch") is False for r in rows):
            raise ValueError("Aligned native intervals do not explain the measured loss")
        if rows != json.loads(target.read_bytes()):
            raise ValueError("Archived analysis differs from original attachments")
    else:
        target.write_text(json.dumps(rows, indent=2) + "\n")


if __name__ == "__main__":
    main()
