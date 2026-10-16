#!/usr/bin/env python3
"""Owned P03 packet-copy control and independently built host PCM references.

The host FFmpeg is independent of CoreAudio, but shares decoder ancestry with
Android FFmpeg and the Apple Dolby/DTS bridge. No physical output claim is implied.
Only explicit regeneration writes fixtures; normal tests consume pinned bytes.
"""
import array
import base64
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'packages/yl_player/example/assets/test_media/pcm_alignment'
SOURCE = ROOT / 'packages/yl_player/example/assets/test_media/format_matrix'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    names = ['ac3-51', 'eac3', 'dts', 'flac']
    sources = [SOURCE / f'mkv-avc-{name}.mkv' for name in names]
    fixture = OUT / 'p03-pcm-switch.mkv'
    command = ['ffmpeg', '-v', 'error', '-y', '-copyts']
    for source in sources:
        command += ['-i', str(source)]
    command += ['-map', '0:v:0']
    for i in range(4):
        command += ['-map', f'{i}:a:0']
    command += ['-c', 'copy', '-fflags', '+bitexact', '-avoid_negative_ts', 'disabled', str(fixture)]
    subprocess.run(command, check=True)
    def packet_hashes(path, selector):
        value = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', selector,
            '-show_packets', '-show_entries', 'packet=data_hash', '-show_data_hash', 'sha256', '-of', 'json', str(path)]))
        return [item['data_hash'] for item in value['packets']]
    identities = {}
    for selector, source, original in [('v:0', sources[0], 'v:0')] + [(f'a:{i}', source, 'a:0') for i, source in enumerate(sources)]:
        packets = packet_hashes(fixture, selector)
        assert packets == packet_hashes(source, original), (selector, 'packet copy changed bytes')
        identities[selector] = dict(packets=len(packets), sha256=hashlib.sha256('\n'.join(packets).encode()).hexdigest())
    rows = []
    for i, name in enumerate(names):
        frames = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', f'a:{i}', '-show_frames', '-of', 'json', str(fixture)]))['frames']
        offsets = []; total = 0
        for frame in frames:
            offsets.append(dict(ptsUs=round(float(frame['pts_time'])*1e6), offset=total, count=frame['nb_samples']))
            total += frame['nb_samples']
        assert total == 192000
        for channels in ([6, 2] if i == 0 else [2]):
            cmd = ['ffmpeg', '-v', 'error', '-i', str(fixture), '-map', f'0:a:{i}', '-ac', str(channels), '-f', 'f32le', '-']
            # Integer stereo output normalizes its matrix to avoid clipping;
            # FFmpeg float stereo defaults to an unnormalized matrix instead.
            # The product's declared Lo/Ro policy excludes LFE and uses sqrt(1/2)
            # for center/surround, rather than the file's optional mix metadata.
            # Use the host pan filter (not product swresample) as the oracle.
            if i == 0 and channels == 2:
                cmd = ['ffmpeg', '-v', 'error', '-i', str(fixture), '-map', f'0:a:{i}',
                    '-af', 'pan=stereo|FL<FL+0.70710678*FC+0.70710678*SL|FR<FR+0.70710678*FC+0.70710678*SR',
                    '-f', 's16le', '-']
                integer = array.array('h', subprocess.check_output(cmd))
                pcm = array.array('f', (value / 32768 for value in integer)).tobytes()
                reference_format = 'explicit normalized LoRo pan to s16le, represented as float'
            else:
                pcm = subprocess.check_output(cmd)
                reference_format = 'f32le'
            assert len(pcm) == total * channels * 4
            # Include complete boundary packets, not just steady-state tones.
            windows = []
            for start, count in [(0, 8192), (115200, 14400), (total-4096, 4096)]:
                windows.append(dict(start=start, count=count, f32le=base64.b64encode(pcm[start*channels*4:(start+count)*channels*4]).decode()))
            rows.append(dict(track=i+1, codec=name, channels=channels, rate=48000, frames=total,
                             referenceFormat=reference_format, packetFrames=offsets, windows=windows, referenceCommand=[v.replace(str(ROOT)+'/', '') for v in cmd], pcmSha256=hashlib.sha256(pcm).hexdigest()))
    output = dict(schema=1, fixtureSha256=sha(fixture),
        reference='Host FFmpeg; independent implementation for CoreAudio FLAC; shared decoder ancestry for Dolby, DTS and Android.',
        ffmpegVersion=subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0],
        sources={str(p.relative_to(ROOT)):sha(p) for p in sources}, packetIdentity=identities,
        muxCommand=[s.replace(str(ROOT)+'/', '') for s in command], tracks=rows)
    (OUT/'p03-pcm-reference.json').write_text(json.dumps(output,separators=(',',':'))+'\n')

if __name__ == '__main__':
    main()
