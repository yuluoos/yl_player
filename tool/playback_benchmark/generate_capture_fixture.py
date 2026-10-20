#!/usr/bin/env python3
"""Generate owned, silent 12s / 10Hz 16-bar frame IDs (0xA500..0xA577)."""
import argparse
from pathlib import Path
import subprocess


def generate(path):
    if path.exists(): raise ValueError('fresh fixture required')
    command=['ffmpeg','-v','error','-f','rawvideo','-pixel_format','rgb24','-video_size','480x270',
        '-framerate','10','-i','pipe:0','-an','-c:v','libx264','-preset','medium','-crf','12',
        '-g','10','-pix_fmt','yuv420p','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709',
        '-movflags','+faststart',str(path)]
    process=subprocess.Popen(command,stdin=subprocess.PIPE)
    try:
        for frame in range(120):
            word=0xA500|frame
            line=b''.join(bytes([255 if word&(1<<(15-bit)) else 0])*3*30 for bit in range(16))
            process.stdin.write(line*270)
        process.stdin.close()
        if process.wait(timeout=60): raise ValueError('fixture encoding failed')
    finally:
        if process.poll() is None: process.kill();process.wait()
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('output',type=Path)
    generate(p.parse_args().output)
