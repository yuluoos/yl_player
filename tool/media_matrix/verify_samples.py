#!/usr/bin/env python3
"""Decode owned fixtures with the host FFmpeg, separately from the player."""
import array
import json
from pathlib import Path
import subprocess

from catalog import MEDIA, validate_case, validate_coverage


def main():
    data = json.loads((Path(__file__).parent / 'cases.json').read_text())
    validate_coverage(data['cases'])
    results=[]
    for row in data['cases']:
        validate_case(row, MEDIA)
        path=MEDIA/row['file']
        if row['integrity']=='truncated':
            result=subprocess.run(['ffprobe','-v','error','-show_streams',str(path)],capture_output=True)
            if result.returncode == 0: raise ValueError('truncated input unexpectedly probed')
            results.append({'caseId':row['id'],'sha256':row['sha256'],'probe':'rejected'})
            continue
        probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',str(path)]))
        v=next(s for s in probe['streams'] if s['codec_type']=='video')
        a=next(s for s in probe['streams'] if s['codec_type']=='audio')
        if (v['codec_name'],v['pix_fmt'],a['codec_name'],a['channels']) != (row['video']['codec'],row['video']['pixelFormat'],row['audio']['codec'],row['audio']['channels']):
            raise ValueError('independent stream probe mismatch')
        raw=subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-an','-vf',r'select=eq(n\,12)+eq(n\,36)+eq(n\,60)+eq(n\,84),scale=1:1','-fps_mode','passthrough','-pix_fmt','rgb24','-f','rawvideo','-'])
        expected=[255,0,0,0,255,0,0,0,255,255,255,255]
        if len(raw)!=12 or max(abs(a-b) for a,b in zip(raw,expected))>24:
            raise ValueError('decoded color markers differ')
        pcm=subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-vn','-ar','48000','-f','f32le','-'])
        samples=array.array('f');samples.frombytes(pcm)
        channels=row['audio']['channels']; freq=[]
        for second in range(4):
            per_channel=[]
            for channel in range(channels):
                segment=samples[int((second+.2)*48000)*channels+channel:int((second+.8)*48000)*channels:channels]
                if len(segment)<28000: raise ValueError('decoded audio marker missing')
                crossings=sum(x<=0<y for x,y in zip(segment,segment[1:]))
                measured=crossings*48000/len(segment)
                expected_hz = 60+10*second if channels == 6 and channel == 3 else 440+220*second+55*channel
                if abs(measured-expected_hz)>6: raise ValueError(f'decoded tone marker differs: {row["id"]} second={second} channel={channel} measured={measured}')
                per_channel.append(round(measured,3))
            freq.append(per_channel)
        results.append({'caseId':row['id'],'sha256':row['sha256'],'rgb':list(raw),'toneHz':freq,'fixtureDecode':'passed','playerOutputVerified':False})
    version=subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0]
    print(json.dumps({'ffmpeg':version,'method':'host independent decode; color error<=24/255, tone frequency error<=6Hz; fixture validity only','results':results},indent=2))


if __name__=='__main__': main()
