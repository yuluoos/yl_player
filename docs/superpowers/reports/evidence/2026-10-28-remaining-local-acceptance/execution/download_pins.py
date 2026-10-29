from pathlib import Path
import subprocess,hashlib,tarfile,json
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-local-acceptance/yl_player')
out=Path('/private/tmp/yl-local-acceptance/downloads');out.mkdir(exist_ok=True)
items=[]
for file,key in [('ffmpeg-9.0.1.lock','FFMPEG'),('opus-1.6.1.lock','OPUS'),('dav1d.lock','DAV1D')]:
 p=dict(x.split('=',1) for x in (root/'packages/yl_player_media_core/tool/apple_ffmpeg'/file).read_text().splitlines())
 items.append((key,p[key+'_URL'],p[key+'_SHA256']))
 if key=='FFMPEG':items.append(('FFMPEG_SIGNATURE',p['FFMPEG_SIGNATURE_URL'],None))
items.append(('MEDIAMTX','https://github.com/bluenviron/mediamtx/releases/download/v1.21.1/mediamtx_v1.21.1_darwin_arm64.tar.gz','25e20ed41611f1f3103b8359585210b29b11b69fa0d9e11bd11b92f7bbcb42ef'))
results=[]
for key,url,expected in items:
 dest=out/key
 code=subprocess.run(['curl','--fail','--location','--retry','2','--max-time','180','--output',str(dest),url],stdout=subprocess.DEVNULL,stderr=(out/(key+'.log')).open('w')).returncode
 digest=hashlib.sha256(dest.read_bytes()).hexdigest() if dest.exists() else None
 results.append(dict(key=key,exitCode=code,sha256=digest,expected=expected))
 (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
 if code or (expected and expected!=digest):raise RuntimeError('pinned download failed '+key)
 if key=='MEDIAMTX':
  peer=Path('/private/tmp/yl-rtmp-foundation');peer.mkdir(exist_ok=True)
  (peer/'mediamtx.tar.gz').write_bytes(dest.read_bytes())
  with tarfile.open(dest) as tar:(peer/'mediamtx').write_bytes(tar.extractfile('mediamtx').read())
  (peer/'mediamtx').chmod(0o755)
 print(key+' verified',flush=True)
