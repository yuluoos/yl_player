"""Tag the owned unqualified AVC reference without changing decoded samples."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / 'packages/yl_player/example/assets/test_media'
source = MEDIA / 'format_matrix/mkv-avc-aac.mkv'
output = MEDIA / 'benchmark_601.mkv'
subprocess.run(['ffmpeg','-v','error','-n','-i',str(source),'-map','0','-c','copy',
    '-bsf:v','h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=6',
    '-color_primaries','bt709','-color_trc','bt709','-colorspace','smpte170m',str(output)],check=True)

def frames(path, stream):
    data=subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-map',stream,
        '-f','framemd5','-'],text=True)
    return [line.split(',')[-1].strip() for line in data.splitlines() if line and not line.startswith('#')]

counts={}
for stream in ['0:v:0','0:a:0']:
    original, tagged = frames(source,stream), frames(output,stream)
    assert original and original==tagged
    counts[stream]=len(original)
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',str(output)]))
v=next(s for s in probe['streams'] if s['codec_type']=='video')
assert (v['color_space'],v['color_primaries'],v['color_transfer'],v['color_range'])==('smpte170m','bt709','bt709','tv')
print(json.dumps(dict(sourceSha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    sha256=hashlib.sha256(output.read_bytes()).hexdigest(),matchingDecodedFrameCounts=counts,
    method='metadata-only control; identical decoded YUV and audio frame hashes, not a production correction',
    matrix='bt601',primaries='bt709',transfer='bt709',
    ffmpeg=subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0]),indent=2))
