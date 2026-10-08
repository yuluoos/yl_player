"""Generate owned synthetic long media; no downloads or repeated playback."""
import json
import subprocess
from run_resources import EXAMPLE, digest

output=EXAMPLE/'assets/test_media/format_matrix/continuous-avc-aac.mkv'
command=['ffmpeg','-v','error','-n','-f','lavfi','-i','testsrc=size=320x180:rate=24:duration=1260',
    '-f','lavfi','-i','anullsrc=channel_layout=stereo:sample_rate=48000',
    '-t','1260','-c:v','libx264','-preset','veryfast','-crf','28','-g','48','-pix_fmt','yuv420p',
    '-c:a','aac','-b:a','64k',str(output)]
subprocess.run(command,check=True,timeout=300)
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_format','-show_streams','-of','json',str(output)],text=True))
assert 1259<=float(probe['format']['duration'])<=1261
assert [s['codec_name'] for s in probe['streams']]==['h264','aac']
print(json.dumps(dict(command=command,sha256=digest(output),bytes=output.stat().st_size,
    ffmpeg=subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0],probe=probe),indent=2))
