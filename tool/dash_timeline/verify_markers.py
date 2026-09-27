#!/usr/bin/env python3
"""Decode owned reference fragments independently of the DASH compiler."""
import array
import json
from pathlib import Path
import subprocess
import tempfile

MEDIA = Path(__file__).resolve().parents[2] / 'packages/yl_player/example/assets/test_media/dash_timeline'
COLORS = [[(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)],
          [(255, 255, 0), (0, 255, 255), (255, 0, 255), (0, 0, 0)]]

def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)

def main():
    evidence = []
    with tempfile.TemporaryDirectory(prefix='yl-dash-clock-') as directory:
        for period in range(2):
            folder = MEDIA / f'period{period}'
            paths = []
            tracks = []
            for track in range(2):
                path = Path(directory) / f'{period}-{track}.mp4'
                path.write_bytes((folder / f'init-{track}.m4s').read_bytes() + b''.join(
                    p.read_bytes() for p in sorted(folder.glob(f'chunk-{track}-*.m4s'))))
                paths.append(path)
                probe = json.loads(run('ffprobe', '-v', 'error', '-show_packets', '-show_streams', '-of', 'json', str(path)))
                packets = probe['packets']
                tracks.append(dict(timeBase=probe['streams'][0]['time_base'],
                                   firstPTS=packets[0]['pts'], lastPTS=packets[-1]['pts'],
                                   lastDuration=packets[-1]['duration']))
            audio = array.array('f', run('ffmpeg', '-v', 'error', '-i', str(paths[1]), '-f', 'f32le', '-ac', '1', '-ar', '48000', '-'))
            markers = []
            for second in range(4):
                rgb = list(run('ffmpeg', '-v', 'error', '-ss', str(second + .5), '-i', str(paths[0]),
                               '-frames:v', '1', '-vf', 'crop=2:2:160:90', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-')[:3])
                assert len(rgb) == 3 and all(abs(a-b) <= 5 for a, b in zip(rgb, COLORS[period][second])), (period, second, rgb)
                samples = audio[int((second + .25) * 48000):int((second + .75) * 48000)]
                assert len(samples) == 24000
                hz = sum(a <= 0 < b for a, b in zip(samples, samples[1:])) * 2
                assert abs(hz - 440 * (second+1)) <= 4, (period, second, hz)
                markers.append(dict(programSecond=period*4+second+.5, rgb=rgb, measuredToneHz=hz))
            evidence.append(dict(period=period, tracks=tracks, markers=markers))
    print(json.dumps(dict(reference=evidence, scope='Offline decoded original media; no physical output or live AV sync measurement'), indent=2))

if __name__ == '__main__': main()
