from pathlib import Path
import subprocess,json,time,os,datetime
b=Path.cwd()/'build/macos-av1-20261103-resumed';r=b/'untraced-control';r.mkdir()
plan=dict(diagnosticOnly=True,maximumSeconds=180,app=str(b/'final-candidate.app'),sdkImages=json.loads((b/'final-qualification/sdk-images.json').read_text()),started=datetime.datetime.now().astimezone().isoformat())
(r/'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
env={**os.environ,'NSUnbufferedIO':'YES','YL_AV1_VISIBLE_QUALIFICATION':'1','YL_AV1_PHASE':'baseline'};env.pop('YL_TRIAL_LIMITS',None)
with (r/'raw.log').open('w') as log:
 p=subprocess.Popen([str(b/'final-candidate.app/Contents/MacOS/yl_player_example')],env=env,stdout=log,stderr=log);(r/'pid').write_text(str(p.pid));start=time.monotonic_ns()
 a=subprocess.Popen(['caffeinate','-d','-i','-u','-t','200','-w',str(p.pid)])
 print('PLAYER',p.pid,flush=True)
 try:code=p.wait(timeout=180);forced=False
 except subprocess.TimeoutExpired:p.terminate();code=p.wait(timeout=10);forced=True
 end=time.monotonic_ns();a.wait(timeout=10)
 lines=(r/'raw.log').read_text().splitlines();clock=None;diags=[]
 for l in lines:
  if 'QUAL_CLOCK ' in l:clock=json.loads(l.split('QUAL_CLOCK ',1)[1])['hostNs']
  if 'QUAL_TIMED_DIAGNOSTICS ' in l:diags.append(clock)
 receipt=dict(pid=p.pid,exit=code,forced=forced,elapsedSeconds=(end-start)/1e9,exitObservedNs=end,diagnosticsClockNs=diags,exitAfterFirstDiagnosticsSeconds=(end-diags[0])/1e9 if diags else None,ended=datetime.datetime.now().astimezone().isoformat())
 (r/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt),flush=True)
