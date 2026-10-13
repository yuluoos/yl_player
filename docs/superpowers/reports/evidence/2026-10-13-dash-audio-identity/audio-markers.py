from pathlib import Path
import subprocess,hashlib,struct,json
root=Path('packages/yl_player/example/assets/test_media/dash');out=[]
for period,target in [(0,440),(1,660)]:
 names=[f'period{period}/init-1.m4s']+[f'period{period}/chunk-1-{i:05}.m4s' for i in range(1,6)]
 data=b''.join((root/n).read_bytes() for n in names)
 path=Path(f'/private/tmp/yl-audio-tone-{period}.mp4');path.write_bytes(data)
 command=['/opt/homebrew/bin/ffmpeg','-hide_banner','-loglevel','error','-i',str(path),'-map','0:a:0','-f','f32le','-ac','1','-ar','48000','pipe:1']
 pcm=subprocess.check_output(command);samples=struct.unpack('<'+'f'*(len(pcm)//4),pcm)[4096:100096]
 crossings=sum(a<=0<b for a,b in zip(samples,samples[1:]));frequency=crossings*48000/(len(samples)-1)
 assert abs(frequency-target)<2,(frequency,target)
 out.append({'sourceFiles':{str(root/n):hashlib.sha256((root/n).read_bytes()).hexdigest() for n in names},'command':command,'pcmSha256':hashlib.sha256(pcm).hexdigest(),'samples':len(pcm)//4,'measuredHz':frequency,'expectedHz':target,'toleranceHz':2})
result={'method':'Independent host FFmpeg AAC decode of existing owned fixture bytes; zero-crossing measurement after encoder warmup. This proves distinct source tones, not physical AVPlayer audio output.','ffmpeg':subprocess.check_output(['/opt/homebrew/bin/ffmpeg','-version'],text=True).splitlines()[0],'results':out}
Path('/private/tmp/audio-marker-reference.json').write_text(json.dumps(result,indent=2)+'\n');print([(r['measuredHz'],r['expectedHz']) for r in out])
