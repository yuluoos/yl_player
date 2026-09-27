#!/usr/bin/env python3
"""Owned original marker media + non-production timeline experiment manifests."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'packages/yl_player/example/assets/test_media/dash_timeline'
COLORS = [['red','lime','blue','white'], ['yellow','cyan','magenta','black']]

def generate_media(folder, colors, duration=4):
    folder.mkdir(parents=True, exist_ok=True)
    video = 'color=c=black:s=320x180:r=24:d=4' + ''.join(
        f",drawbox=color={color}:t=fill:enable='gte(t,{i})*lt(t,{i+1})'" for i,color in enumerate(colors))
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',video,
        '-f','lavfi','-i','aevalsrc=0.12*sin(2*PI*440*(floor(t)+1)*t):s=48000:d=4',
        '-t',str(duration),'-map','0:v:0',*(['-map','1:a:0'] if duration==4 else []),
        '-c:v','libx264','-preset','veryfast','-profile:v','baseline','-level:v','3.0','-pix_fmt','yuv420p',
        '-g','24','-keyint_min','24','-sc_threshold','0','-c:a','aac','-b:a','64k',
        '-f','dash','-seg_duration','1','-use_template','1','-use_timeline','1',
        '-init_seg_name','init-$RepresentationID$.m4s','-media_seg_name','chunk-$RepresentationID$-$Number%05d$.m4s',
        str(folder/'generated.mpd')],check=True)
    (folder/'generated.mpd').unlink()

def shift(source,delta):
    data=bytearray(source)
    def walk(start,end):
        while start<end:
            size,kind=struct.unpack_from('>I4s',data,start)
            assert 8<=size<=end-start
            if kind in (b'moof',b'traf'): walk(start+8,start+size)
            if kind in (b'tfdt',b'sidx'):
                version=data[start+8]; width=4 if version==0 else 8
                pos=start+(12 if kind==b'tfdt' else 20)
                fmt='>I' if width==4 else '>Q'
                struct.pack_into(fmt,data,pos,struct.unpack_from(fmt,data,pos)[0]+delta)
            start+=size
    walk(0,len(data));return bytes(data)

def period(n,start=None,duration=4,origins=(0,0),large=False,base=None):
    attrs=f' id="period{n}"'
    if start is not None: attrs+=f' start="PT{start}S"'
    if duration is not None: attrs+=f' duration="PT{duration}S"'
    tracks=[]
    for track in [0,1]:
        scale=12288 if track==0 else 48000
        ds=[12288]*4 if track==0 else [47104,48128,48128,48128,512]
        factor=10**9 if large else 1
        offset=origins[track]*scale;cursor=offset
        entries=[]
        for d in ds:
            entries.append(f'<S t="{cursor*factor}" d="{d*factor}"/>');cursor+=d
        kind='video' if track==0 else 'audio'
        attrs2='codecs="avc1.42c01e" width="320" height="180" bandwidth="350000"' if track==0 else 'codecs="mp4a.40.2" audioSamplingRate="48000" bandwidth="64000"'
        tracks.append(f'<AdaptationSet contentType="{kind}" mimeType="{kind}/mp4"><Representation id="{track}" {attrs2}><SegmentTemplate timescale="{scale*factor}" presentationTimeOffset="{offset*factor}" initialization="init-{track}.m4s" media="chunk-{track}-$Number%05d$.m4s"><SegmentTimeline>{"".join(entries)}</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>')
    return f'<Period{attrs}>{base or f"<BaseURL>period{n}/</BaseURL>"}{"".join(tracks)}</Period>'

def mpd(periods,total=None):
    return '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"'+(f' mediaPresentationDuration="PT{total}S"' if total is not None else '')+'>'+''.join(periods)+'</MPD>'

def hls(prefix, periods, clip=False):
    for track in [0,1]:
        lines=['#EXTM3U','#EXT-X-VERSION:7','#EXT-X-PLAYLIST-TYPE:VOD','#EXT-X-TARGETDURATION:2','#EXT-X-MEDIA-SEQUENCE:0']
        for n,folder in enumerate(periods):
            if n: lines+=['#EXT-X-DISCONTINUITY']
            lines+=[f'#EXT-X-MAP:URI="{folder}/init-{track}.m4s"']
            ds=[1]*4 if track==0 else [47104/48000,48128/48000,48128/48000,48128/48000,512/48000]
            remaining=3.5 if clip else 4
            for i,d in enumerate(ds):
                if remaining<=0: break
                declared=min(d,remaining);remaining-=declared
                lines += [f'#EXTINF:{declared:.9f},',f'{folder}/chunk-{track}-{i+1:05}.m4s']
        (OUT/f'{prefix}-{track}.m3u8').write_text('\n'.join(lines+['#EXT-X-ENDLIST'])+'\n')
    (OUT/f'{prefix}.m3u8').write_text(f'#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="{prefix}-1.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=414000,CODECS="avc1.42c01e,mp4a.40.2",RESOLUTION=320x180,AUDIO="audio"\n{prefix}-0.m3u8\n')

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    for n in [0,1]: generate_media(OUT/f'period{n}',COLORS[n])
    generate_media(OUT/'fractional',COLORS[0],duration=1/3)
    shifted=OUT/'independent';shifted.mkdir(exist_ok=True)
    for p in (OUT/'period0').glob('*.m4s'):
        track=int(p.stem.split('-')[1]);delta=(10 if track==0 else 20)*(12288 if track==0 else 48000)
        (shifted/p.name).write_bytes(p.read_bytes() if p.name.startswith('init') else shift(p.read_bytes(),delta))
    cases={
        'independent-pto':(mpd([period(0,0,origins=(10,20),base='<BaseURL>independent/</BaseURL>')],4), 'P=(videoTicks/12288)-10=(audioTicks/48000)-20, duration 4'),
        'clip-end':(mpd([period(0,0,duration=3.5)],3.5), 'P in [0,7/2); encoded final segment extends to 4'),
        'gap':(mpd([period(0,0),period(1,5)],9), 'Period0 [0,4); gap [4,5); Period1 [5,9)'),
        'overlap':(mpd([period(0,0),period(1,3)],7), 'Period0 [0,4); Period1 [3,7); overlap [3,4), ownership needs policy'),
        'unknown-middle':(mpd([period(0,0,duration=None),period(1,None)]), 'middle boundary undeclared; raw finite track ends=4, do not silently infer authority'),
        'multiple-base':(mpd([period(0,0,base='<BaseURL>period0/</BaseURL><BaseURL>period1/</BaseURL>')],4), 'two alternatives; same duration, distinct frame markers, selection/failover unspecified'),
        'fractional-microsecond':(mpd([f'<Period><BaseURL>fractional/</BaseURL><AdaptationSet mimeType="video/mp4"><Representation id="0" codecs="avc1.42c01e" width="320" height="180" bandwidth="350000"><SegmentTemplate timescale="12288" initialization="init-0.m4s" media="chunk-0-$Number%05d$.m4s"><SegmentTimeline><S t="0" d="4096"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period>']), 'exact duration=1/3 second=1000000/3 microseconds; no integer-microsecond endpoint'),
    }
    for name,(xml,_) in cases.items(): (OUT/f'{name}.mpd').write_text(xml+'\n')
    (OUT/'manifest.mpd').write_text(mpd([period(0,0),period(1,4)],8)+'\n')
    (OUT/'large-exact.mpd').write_text(mpd([period(0,0,large=True),period(1,4,large=True)],8)+'\n')
    rows=[dict(id=k,mpd=k+'.mpd',expected=v[1],productionAcceptance='rejected') for k,v in cases.items()]
    (OUT/'matrix.json').write_text(json.dumps(rows,indent=2)+'\n')
    cues=['WEBVTT','']
    for i,color in enumerate(sum(COLORS,[])):
        cues += [f'00:00:{i:02}.000 --> 00:00:{i+1:02}.000',f'program={i} color={color} tone={440*((i%4)+1)}Hz','']
    (OUT/'reference.vtt').write_text('\n'.join(cues))
    hls('baseline',['period0','period1']);hls('independent',['independent']);hls('clip',['period0'],clip=True)
    hashes=[f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(OUT)}' for p in sorted(OUT.rglob('*')) if p.is_file() and p.name not in ['SHA256SUMS','README.md']]
    (OUT/'SHA256SUMS').write_text('\n'.join(hashes)+'\n')

if __name__=='__main__': main()
