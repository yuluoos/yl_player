import os,sys,time,json,subprocess,signal
from pathlib import Path
root=Path(sys.argv[1]);out=Path('/private/tmp/yl-abr-recovery-20261027-host');out.mkdir(exist_ok=False)
env=os.environ.copy();env['PATH']='/private/tmp/yl-remaining-20261026-python/bin:/Users/yy2021_8689/flutter/bin:/opt/homebrew/share/android-commandlinetools/platform-tools:'+env['PATH'];env['JAVA_HOME']='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home'
def stop(p):
 if p.poll() is None:
  os.killpg(p.pid,signal.SIGTERM)
  try:p.wait(timeout=15)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
adb='/opt/homebrew/share/android-commandlinetools/platform-tools/adb';serial='emulator-5580';emulator='/opt/homebrew/share/android-commandlinetools/emulator/emulator'
existing=subprocess.check_output([adb,'devices'],text=True)
if serial in existing:raise SystemExit('Chosen emulator serial already owned; no launch')
with (out/'android-emulator.log').open('w') as log:
 command=[emulator,'-avd','TV_64bit_1_5G_32G','-port','5580','-read-only','-no-snapshot','-no-window','-no-audio','-no-boot-anim']
 (out/'android-emulator-command.json').write_text(json.dumps(command,indent=2)+'\n')
 process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=env)
 try:
  deadline=time.monotonic()+240;booted=False
  while time.monotonic()<deadline and process.poll() is None:
   status=subprocess.run([adb,'-s',serial,'shell','getprop','sys.boot_completed'],capture_output=True,text=True,timeout=10)
   if status.returncode==0 and status.stdout.strip()=='1':booted=True;break
   time.sleep(2)
  if not booted:raise RuntimeError('Owned Android emulator did not boot')
  receipt={key:subprocess.check_output([adb,'-s',serial,'shell','getprop',key],text=True).strip() for key in ['ro.build.version.sdk','ro.product.cpu.abi','ro.product.model','ro.build.fingerprint']}
  receipt.update(emulatorPid=process.pid,readOnly=True,physicalDevice=False)
  (out/'android-environment.json').write_text(json.dumps(receipt,indent=2)+'\n')
  subprocess.run(['python3','-u','/private/tmp/yl-abr-recovery-runs.py',str(root)],cwd=root,env=env,check=True)
 finally:
  stop(process);(out/'android-cleanup.json').write_text(json.dumps({'ownedEmulatorExited':process.poll() is not None,'exitCode':process.returncode})+'\n')
