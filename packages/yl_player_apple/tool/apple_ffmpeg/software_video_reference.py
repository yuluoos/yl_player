"""Test-only owned packets and independent libaom/libvpx planar references."""
import base64
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys

root=Path(__file__).resolve().parents[4]
out=Path(sys.argv[1]);out.mkdir(exist_ok=True)
media=root/'packages/yl_player/example/assets/test_media/format_matrix'
source=media/'webm-vp9-vorbis.webm'
def unpack(text):
    return bytes.fromhex(''.join(line.split(': ',1)[1].split('  ',1)[0].replace(' ','')
                                for line in text.splitlines() if ': ' in line))
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0',
    '-show_streams','-show_packets','-show_data','-of','json',str(source)]))
s=probe['streams'][0]
vp9=dict(caseId='vp9-main8',codec='vp9',width=s['width'],height=s['height'],bitDepth=8,
         profile=0,configuration='',frames=[dict(data=base64.b64encode(unpack(p['data'])).decode(),
         ptsUs=round(float(p['pts_time'])*1e6),durationUs=round(float(p['duration_time'])*1e6))
         for p in probe['packets']])
(out/'vp9-main8.json').write_text(json.dumps(vp9)+'\n')
records=[]
for name in ('av1-main8','av1-main10','vp9-main8'):
    src=out/(name+'.json') if name.startswith('vp9') else root/'tool/decoder_probe/fixtures'/(name+'.json')
    d=json.loads(src.read_text());(out/(name+'.json')).write_bytes(src.read_bytes())
    ivf=out/(name+'.ivf');data=bytearray(struct.pack('<4sHH4sHHIIII',b'DKIF',0,32,
        b'AV01' if d['codec']=='av1' else b'VP90',d['width'],d['height'],1_000_000,1,len(d['frames']),0))
    for frame in d['frames']:
        packet=base64.b64decode(frame['data']);data.extend(struct.pack('<IQ',len(packet),frame['ptsUs']));data.extend(packet)
    ivf.write_bytes(data);raw=out/(name+'.yuv')
    if d['codec']=='av1':
        subprocess.run(['/opt/homebrew/opt/aom/bin/aomdec','--codec=av1','--rawvideo','--i420',
                        '--output='+str(raw),str(ivf)],check=True)
        decoder='libaom'
    else:
        subprocess.run(['ffmpeg','-v','error','-c:v','libvpx-vp9','-i',str(ivf),'-pix_fmt','yuv420p',
                        '-f','rawvideo','-y',str(raw)],check=True)
        decoder='libvpx-vp9'
    assert raw.stat().st_size==len(d['frames'])*d['width']*d['height']*3//2*(2 if d['bitDepth']==10 else 1)
    subprocess.run(['ffmpeg','-v','error','-r','24','-i',str(ivf),'-c:v','copy','-y',str(out/(name+'.mkv'))],check=True)
    records.append(dict(caseId=name,fixtureSha256=hashlib.sha256(src.read_bytes()).hexdigest(),
                        referenceDecoder=decoder,referenceSha256=hashlib.sha256(raw.read_bytes()).hexdigest()))
print(json.dumps(records,sort_keys=True))
