"""Verify archived CI #127 timing evidence offline without changing any files."""
import gzip
import importlib.util
import json
from pathlib import Path

root = Path(__file__).resolve().parent


def read(name):
    data = (root / name).read_bytes()
    return json.loads(gzip.decompress(data) if name.endswith(".gz") else data)


spec = importlib.util.spec_from_file_location("timing_analysis", root / "analyze-native-render-trace.py")
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)
joined = read("ci127-audio-timing-attachments.json.gz")
matrix = [x["row"] for x in joined if x["row"].get("kind") != "nativeRenderTrace"]
traces = [x for x in joined if x["row"].get("kind") == "nativeRenderTrace"]
canonical = lambda rows: sorted(json.dumps(x, sort_keys=True) for x in rows)
assert canonical(matrix) == canonical(read("ci127-macos-audio-matrix.json.gz"))
assert len(matrix) == len(traces) == 14
assert sum(x.get("kind") != "directNativeControl" for x in matrix) == 12
assert all(x["submittedMarker"]["frames"] == x["buffers"] * 1024
           and x["submittedMarker"]["errors"] == 0 for x in matrix)
stored = read("ci127-macos-render-timing-analysis.json.gz")
proofs = read("ci127-audio-native-timeline-loss.json")
for item in traces:
    row, attachment = item["row"], item["attachment"]
    result = next(x for x in stored
                  if x["traceAttachment"]["exportedFileName"] == attachment["exportedFileName"])
    trace = row["trace"]
    recomputed = analysis.analyze(trace)
    assert recomputed == result["fullTrace"]
    assert recomputed["overflow"] == recomputed["removeStatus"] == 0
    assert not recomputed["unmatched"] and not recomputed["stampMismatches"]
    missing = result["expectedFrames"] - result["marker"]["frames"]
    if not missing:
        continue
    proof = next(x for x in proofs if x["identity"] == result["identity"])
    first = next(x for x in trace["entries"] if x[5] & trace["preRenderMask"])
    tap = result["capture"]["firstCallbackTime"]
    assert first[2] == tap["sampleTime"] == 0
    assert first[1] == tap["hostTimeTicks"] == proof["nativeAndTapFirstHostTicks"]
    assert result["capture"]["timestampJumps"] == 0 and trace["sampleRate"] == 48000
    assert not result["identity"].get("starvation") and not result["identity"].get("pausedEOF")
    start = result["capture"]["leadingZeros"] - result["capture"]["firstMarker"]
    end = start + result["expectedFrames"]
    assert (start, end) == (proof["inputTimelineStart"], proof["inputTimelineEndExclusive"])
    predicted = 0
    jumps = recomputed["clockDiscontinuities"]
    assert len(jumps) == len(proof["intervals"])
    for jump, interval in zip(jumps, proof["intervals"]):
        index = jump["index"]
        previous, post, current = trace["entries"][index - 2:index + 1]
        lower, upper = previous[2] + previous[3], current[2]
        assert upper - lower == jump["sampleDeltaMinusPreviousFrames"] > 0
        assert (lower, upper) == (interval["nativeSkippedStart"], interval["nativeSkippedEndExclusive"])
        intersection = max(0, min(upper, end) - max(lower, start))
        assert intersection == interval["intersectionWithInputFrames"]
        predicted += intersection
    assert predicted == missing == proof["actualMissingFrames"]
    assert predicted == proof["predictedMissingFramesFromSkippedNativeIntervals"]
assert sorted(x["actualMissingFrames"] for x in proofs) == [264, 2560, 11968]
print("Verified 12 matrix rows, 2 native controls, 14 complete traces and 3 exact timeline-loss matches")
