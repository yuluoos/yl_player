import hashlib, json, os, signal, subprocess, sys, tempfile, threading
from pathlib import Path
sys.path.insert(0, str(Path.cwd()/'tool/playback_network'))
from prepare_fixture import create
from network_profile import make_server, load_profiles
out=Path(tempfile.mkdtemp(prefix='p04-fixed-public-',dir='/private/tmp'))
receipt=create(out/'media',missing_high_after=2)
profile=load_profiles(Path('tool/playback_network/profiles.json'))['down-and-recover-v1']
log=(out/'requests.jsonl').open('w')
server=make_server(out/'media',profile,log,start_on_first_get=True,run_id='fixed-period-public')
thread=threading.Thread(target=server.serve_forever,kwargs={'poll_interval':.05});thread.start()
command=['/Users/yy2021_8689/flutter/bin/flutter','test','--no-pub','integration_test/abr_fixed_period_test.dart','-d','macos','--reporter','expanded']
values=dict(YL_ABR_RUN='fixed-period-public',YL_ABR_URL=f'http://127.0.0.1:{server.server_port}/manifest.mpd',YL_ABR_PROFILE=profile.id,YL_ABR_PROFILE_SHA256=profile.sha256,YL_ABR_MEDIA_SHA256=receipt['manifestSha256'])
command += ['--dart-define='+k+'='+v for k,v in values.items()]
process=None;code=None;outcome='failed'
try:
    with (out/'capture.log').open('w') as capture:
        process=subprocess.Popen(command,cwd=Path.cwd()/'packages/yl_player/example',stdout=capture,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            code=process.wait(timeout=360);outcome='completed' if code==0 else 'failed'
        except subprocess.TimeoutExpired:
            outcome='timeout';os.killpg(process.pid,signal.SIGTERM)
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
finally:
    server.shutdown();server.server_close();thread.join();log.close()
    (out/'runner.json').write_text(json.dumps(dict(outcome=outcome,exitCode=code,fixture=receipt,profileHash=profile.sha256,acceptedConnections=server.requests,recordedRequests=server.next_record_id),indent=2)+'\n')
    print(out,flush=True)
sys.exit(0 if code==0 else 1)
