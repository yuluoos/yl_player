import json, os, signal, subprocess, sys, time, uuid
from pathlib import Path
root=Path.cwd(); sys.path.insert(0,str(root/'tool/playback_benchmark'))
from run_timed_video_trace import StartedNotification
base=root/'build/macos-av1-20261103-resumed'; out=base/'thread-trace'; out.mkdir()
name='dev.ylplayer.av1.'+uuid.uuid4().hex; note=StartedNotification(name)
cmd=['xcrun','xctrace','record','--template','System Trace','--all-processes','--notify-tracing-started',name,'--time-limit','210s','--window','15s','--output',str(out/'recording.trace')]
plan=dict(diagnosticOnly=True,formalAcceptance=False,command=cmd,app=str(base/'final-candidate.app'),sdkImages=json.loads((base/'final-qualification/sdk-images.json').read_text()))
(out/'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
p=None; awake=None; started=time.monotonic(); code=None
with (out/'trace.log').open('w') as tl, (out/'raw.log').open('w') as log:
 t=subprocess.Popen(cmd,stdout=tl,stderr=tl)
 try:
  while not note.received():
   if t.poll() is not None: raise RuntimeError('recorder exited before ready')
   if time.monotonic()-started>60: raise RuntimeError('recorder readiness timeout')
   time.sleep(.1)
  print('TRACE_READY',time.monotonic(),flush=True)
  env={**os.environ,'NSUnbufferedIO':'YES','YL_AV1_VISIBLE_QUALIFICATION':'1','YL_AV1_PHASE':'baseline'};env.pop('YL_TRIAL_LIMITS',None)
  p=subprocess.Popen([str(base/'final-candidate.app/Contents/MacOS/yl_player_example')],env=env,stdout=log,stderr=log)
  (out/'pid').write_text(str(p.pid));awake=subprocess.Popen(['caffeinate','-d','-i','-u','-t','200','-w',str(p.pid)])
  print('PLAYER',p.pid,time.monotonic(),flush=True)
  deadline=time.monotonic()+180
  while p.poll() is None and time.monotonic()<deadline:
   if t.poll() is not None: raise RuntimeError('recorder exited during capture')
   time.sleep(.25)
  if p.poll() is None:p.terminate()
  code=p.wait(timeout=10)
  print('PLAYER_EXIT',code,time.monotonic(),flush=True)
 finally:
  if p and p.poll() is None:p.terminate();p.wait(timeout=10)
  if awake:awake.wait(timeout=10)
  if t.poll() is None:t.send_signal(signal.SIGINT)
  tc=t.wait();note.close()
  (out/'receipt.json').write_text(json.dumps(dict(playerExit=code,traceExit=tc,elapsedSeconds=time.monotonic()-started,diagnosticOnly=True),indent=2)+'\n')
  print('TRACE_EXIT',tc,flush=True)
