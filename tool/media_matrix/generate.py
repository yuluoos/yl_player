#!/usr/bin/env python3
"""Generate small original color/tone fixtures; no third-party media is used."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'packages/yl_player/example/assets/test_media/format_matrix'
# MPEG-2 is an auxiliary, conventional PS probe; it adds no video support promise.
CASES = [
    ('mp4-avc-aac', 'mp4', 'mp4', 'libx264', 'aac', 2, 8),
    ('mov-hevc-aac', 'mov', 'mov', 'libx265', 'aac', 2, 8),
    ('mkv-avc-aac', 'mkv', 'matroska', 'libx264', 'aac', 2, 8),
    ('webm-vp9-opus', 'webm', 'webm', 'libvpx-vp9', 'libopus', 2, 8),
    ('flv-avc-mp3', 'flv', 'flv', 'libx264', 'libmp3lame', 2, 8),
    ('ts-avc-ac3', 'ts', 'mpegTs', 'libx264', 'ac3', 2, 8),
    ('ps-mpeg2-mp3', 'mpg', 'mpegPs', 'mpeg2video', 'libmp3lame', 2, 8),
    ('avi-avc-mp3', 'avi', 'avi', 'libx264', 'libmp3lame', 2, 8),
    ('mkv-av1-opus', 'mkv', 'matroska', 'libsvtav1', 'libopus', 2, 8),
    ('mkv-avc-eac3', 'mkv', 'matroska', 'libx264', 'eac3', 2, 8),
    ('mkv-avc-dts', 'mkv', 'matroska', 'libx264', 'dca', 2, 8),
    ('mkv-avc-opus', 'mkv', 'matroska', 'libx264', 'libopus', 2, 8),
    ('mkv-avc-flac', 'mkv', 'matroska', 'libx264', 'flac', 2, 8),
    ('webm-vp9-vorbis', 'webm', 'webm', 'libvpx-vp9', 'vorbis', 2, 8),
    ('mkv-hevc-main10-aac', 'mkv', 'matroska', 'libx265', 'aac', 2, 10),
    ('mkv-avc-ac3-51', 'mkv', 'matroska', 'libx264', 'ac3', 6, 8),
    ('mkv-avc-aac-no-cues', 'mkv', 'matroska', 'libx264', 'aac', 2, 8),
]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rows, commands = [], []
    for name, ext, container, vc, ac, channels, depth in CASES:
        video = 'color=c=red:s=320x180:r=24:d=4'
        for sec, color in [(1, 'lime'), (2, 'blue'), (3, 'white')]:
            video += f",drawbox=x=0:y=0:w=iw:h=ih:color={color}:t=fill:enable='gte(t,{sec})'"
        tones = '|'.join('0.04*sin(2*PI*(60+10*floor(t))*t)' if channels == 6 and c == 3 else f'0.04*sin(2*PI*(440+220*floor(t)+{c*55})*t)' for c in range(channels))
        audio = f'aevalsrc={tones}:s=48000:d=4:c={"stereo" if channels==2 else "5.1"}'
        path = OUT / f'{name}.{ext}'
        cmd = ['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',video,
               '-f','lavfi','-i',audio,'-map','0:v','-map','1:a','-t','4',
               '-c:v',vc,'-pix_fmt','yuv420p10le' if depth==10 else 'yuv420p','-threads','2']
        if vc == 'libx264': cmd += ['-preset','ultrafast','-g','24','-bf','0']
        if vc == 'libx265': cmd += ['-preset','ultrafast','-x265-params','pools=1:frame-threads=1:keyint=24:log-level=error']
        if vc == 'libvpx-vp9': cmd += ['-deadline','realtime','-cpu-used','8','-g','24']
        if vc == 'libsvtav1': cmd += ['-preset','12','-svtav1-params','lp=2','-g','24']
        if vc == 'mpeg2video': cmd += ['-g','12','-b:v','300k']
        cmd += ['-c:a',ac,'-ar','48000','-ac',str(channels)]
        if ac in {'vorbis','dca'}: cmd += ['-strict','-2']
        if ac == 'dca': cmd += ['-b:a','768k']
        if ac == 'ac3' and channels == 6: cmd += ['-b:a','384k']
        if ext in {'mp4','mov'}: cmd += ['-movflags','+faststart']
        if 'no-cues' in name: cmd += ['-live','1']
        cmd += [str(path)]
        subprocess.run(cmd,check=True)
        commands.append([str(Path(a).relative_to(ROOT)) if a.startswith(str(ROOT)) else a for a in cmd])
        probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(path)]))
        # Do not commit machine paths from the independent probe.
        probe['format']['filename']=path.name
        (OUT/f'{name}.probe.json').write_text(json.dumps(probe,indent=2)+'\n')
        v=next(s for s in probe['streams'] if s['codec_type']=='video')
        a=next(s for s in probe['streams'] if s['codec_type']=='audio')
        rows.append({'id':name,'file':path.name,'container':container,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
            'video':{'codec':v['codec_name'],'profile':v.get('profile'),'bitDepth':depth,'pixelFormat':v['pix_fmt'],'width':v['width'],'height':v['height'],'frameRate':v['r_frame_rate']},
            'audio':{'codec':a['codec_name'],'channels':a['channels'],'layout':a.get('channel_layout'),'sampleRate':int(a['sample_rate'])},
            'durationSeconds':4.0,'probedDurationSeconds':float(probe['format']['duration']) if 'duration' in probe['format'] else None,
            'probe':f'{name}.probe.json','source':'owned-generated','integrity':'valid','seekability':'no_cues' if 'no-cues' in name else 'expected_seekable',
            'transports':['file','http'],'platforms':{p:{'implementation':'unverified','verification':'not_run'} for p in ['android','ios','macos']}})
    bad=OUT/'truncated.mp4';bad.write_bytes((OUT/'mp4-avc-aac.mp4').read_bytes()[:32])
    row=json.loads(json.dumps(rows[0]));row.update(id='mp4-truncated',file=bad.name,sha256=hashlib.sha256(bad.read_bytes()).hexdigest(),integrity='truncated',seekability='invalid',probe=None,probedDurationSeconds=None)
    rows.append(row)
    version=subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0]
    data={'schemaVersion':1,'source':'Original lavfi color/tone patterns generated for this repository; no third-party media.',
          'generatorVersion':version,'markers':{'video':['red','lime','blue','white'],'intervalSeconds':1,'audio':'per-second 440/660/880/1100 Hz plus 55 Hz per channel; 5.1 LFE=60/70/80/90 Hz; amplitude0.04'},'cases':rows}
    serialized=json.dumps(data,indent=2)+'\n'
    (OUT/'cases.json').write_text(serialized)
    (Path(__file__).parent/'cases.json').write_text(serialized)
    (OUT/'generation.json').write_text(json.dumps({'ffmpeg':version,'commands':commands},indent=2)+'\n')
    (OUT/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(OUT.iterdir()) if p.name!='SHA256SUMS'))


if __name__ == '__main__': main()
