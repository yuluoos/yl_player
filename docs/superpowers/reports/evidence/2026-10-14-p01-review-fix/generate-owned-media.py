import subprocess,json,base64,hashlib
from pathlib import Path
out=Path('/private/tmp/p01-family-media');out.mkdir(exist_ok=True)
cmd=['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i','color=c=yellow:s=640x360:r=24:d=2','-c:v','libx264','-preset','veryfast','-pix_fmt','yuv420p','-x264-params','keyint=24:min-keyint=24:scenecut=0:open-gop=0:bframes=0:threads=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc','-color_trc','smpte2084','-color_primaries','bt2020','-colorspace','bt2020nc','-f','dash','-format_options','movflags=+write_colr','-seg_duration','1','-use_template','1','-use_timeline','1','-init_seg_name','init-0.m4s','-media_seg_name','chunk-0-$Number%05d$.m4s',str(out/'generated.mpd')]
subprocess.run(cmd,check=True)
files={f'family-pq/{p.name}':base64.b64encode(p.read_bytes()).decode() for p in sorted(out.glob('*.m4s'))}
# Copy these three owned outputs into the committed fixture directory, then
# rebuild native bundles using the repository's canonical packaging command.
import shutil
media=Path('packages/yl_player/example/assets/test_media/dash_timeline/family-pq')
media.mkdir(parents=True,exist_ok=True)
for p in out.glob('*.m4s'): shutil.copy2(p,media/p.name)
subprocess.run(['python3','-B','tool/dash_timeline/package_native_fixture.py'],check=True)
cmd[-1]='family-pq/generated.mpd'
Path('/private/tmp/p01-family-provenance.json').write_text(json.dumps({'purpose':'Owned SDR-coded yellow with actual PQ transfer metadata; selection identity only, not HDR color fidelity','command':cmd,'ffmpeg':subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0],'files':{k:hashlib.sha256(base64.b64decode(v)).hexdigest() for k,v in files.items()}},indent=2)+'\n')
