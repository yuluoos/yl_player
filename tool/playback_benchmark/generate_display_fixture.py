"""Generate an owned, explicitly signalled BT.709 SDR display probe (host FFmpeg)."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / 'packages/yl_player/example/assets/test_media'
output = MEDIA / 'benchmark_sdr.mkv'
video = 'color=c=red:s=320x180:r=24:d=4'
for second, color in [(1, 'lime'), (2, 'blue'), (3, 'white')]:
    video += f",drawbox=x=0:y=0:w=iw:h=ih:color={color}:t=fill:enable='gte(t,{second})'"
# lavfi color defaults to BT.601 coefficients; transform pixels, then signal 709.
video += ',scale=in_color_matrix=bt601:out_color_matrix=bt709,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709'
subprocess.run(['ffmpeg','-v','error','-n','-f','lavfi','-i',video,
    '-i',str(MEDIA/'format_matrix/mkv-avc-aac.mkv'),'-map','0:v','-map','1:a',
    '-c:v','libx264','-preset','medium','-crf','18','-g','24','-pix_fmt','yuv420p',
    '-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709',
    '-c:a','copy','-t','4',str(output)],check=True)
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',str(output)]))
v=next(s for s in probe['streams'] if s['codec_type']=='video')
assert all(v[k]=='bt709' for k in ('color_space','color_transfer','color_primaries'))
raw=subprocess.check_output(['ffmpeg','-v','error','-i',str(output),'-an','-vf',
    r'select=eq(n\,12)+eq(n\,36)+eq(n\,60)+eq(n\,84),scale=1:1',
    '-fps_mode','passthrough','-pix_fmt','rgb24','-f','rawvideo','-'])
assert len(raw)==12 and max(abs(a-b) for a,b in zip(raw,[255,0,0,0,255,0,0,0,255,255,255,255]))<=24
print(json.dumps(dict(sha256=hashlib.sha256(output.read_bytes()).hexdigest(),rgb=list(raw),
    colorSpace='bt709',colorTransfer='bt709',colorPrimaries='bt709',range='tv',
    method='independent host FFmpeg fixture validation; not player output',
    ffmpeg=subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0]),indent=2))
