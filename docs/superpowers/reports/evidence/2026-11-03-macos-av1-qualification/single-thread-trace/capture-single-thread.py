import json, os, signal, subprocess, sys, time, uuid
from pathlib import Path
root=Path.cwd();sys.path.insert(0,str(root/'tool/playback_benchmark'))
from run_timed_video_trace import StartedNotification
b=root/'build/macos-av1-20261103-resumed';out=b/'single-thread-trace';out.mkdir()
options={'Time Profiler': {'contextSwitchSampling':True,'highFrequencySampling':False,'recordKernelStacks':False,'recordWaitingThreads':True}}
(out/'options.json').write_text(json.dumps(options,indent=2)+'\n')
env={**os.environ,'NSUnbufferedIO':'YES','YL_AV1_VISIBLE_QUALIFICATION':'1','YL_AV1_PHASE':'baseline'};env.pop('YL_TRIAL_LIMITS',None)
name='dev.ylplayer.budget.'+uuid.uuid4().hex;note=StartedNotification(name);trigger=None
with (out/'raw.log').open('w') as raw,(out/'trace.log').open('w') as log:
 p=subprocess.Popen([str(b/'single-thread-candidate.app/Contents/MacOS/yl_player_example')],env=env,stdout=raw,stderr=raw);(out/'pid').write_text(str(p.pid))
 awake=subprocess.Popen(['caffeinate','-d','-i','-u','-t','240','-w',str(p.pid)])
 cmd=['xcrun','xctrace','record','--template','Time Profiler','--attach',str(p.pid),'--recording-options',str(out/'options.json'),'--notify-tracing-started',name,'--time-limit','220s','--window','10s','--output',str(out/'recording.trace')]
 (out/'plan.json').write_text(json.dumps(dict(diagnosticOnly=True,formalAcceptance=False,maximumSeconds=180,triggerNativeWallNs=22000000,diagnosticTrialCeilingNs=100000000,command=cmd,pid=p.pid,sdkImages=json.loads((b/'preview-qualification/sdk-images.json').read_text()),decoderThreads=1,hypothesis='Remove dav1d inter-worker waits for this low-resolution AV1 key; diagnostic only'),indent=2)+'\n')
 t=subprocess.Popen(cmd,stdout=log,stderr=log);start=time.monotonic();ready=None
 try:
  while not note.received():
   if t.poll() is not None or p.poll() is not None:raise RuntimeError('process exited before recorder ready')
   if time.monotonic()-start>60:raise RuntimeError('recorder readiness timeout')
   time.sleep(.1)
  ready=time.monotonic();print('READY',p.pid,ready,flush=True)
  while p.poll() is None and time.monotonic()-ready<180:
   if t.poll() is not None:raise RuntimeError('recorder ended during capture')
   lines=(out/'raw.log').read_text().splitlines()
   samples=[l for l in lines if l.startswith('QUAL_SAMPLE ')]
   if samples and int(samples[-1].split()[-1])>22000000:
    trigger=dict(sample=samples[-1],detectedHostNs=time.monotonic_ns(),recordingStartedHostNs=int(ready*1e9));print('TRIGGER',json.dumps(trigger),flush=True);break
   time.sleep(.25)
 finally:
  if t.poll() is None:t.send_signal(signal.SIGINT)
  if p.poll() is None:p.terminate()
  code=p.wait(timeout=10);awake.wait(timeout=10)
  tc=t.wait();note.close()
  receipt=dict(playerExit=code,traceExit=tc,trigger=trigger,elapsedSeconds=time.monotonic()-start,diagnosticOnly=True)
  (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt),flush=True)
