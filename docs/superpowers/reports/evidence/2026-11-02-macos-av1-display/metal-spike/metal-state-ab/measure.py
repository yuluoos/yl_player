import hashlib,json,math,os,subprocess,sys,time
from pathlib import Path
root=Path(__file__).parent
path=root/'optimized/Build/Products/Release/yl_player_example.app'
binary=path/'Contents/MacOS/yl_player_example'
def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
names=['maxOwnedBytes','maxFrames','maxPacketBytes','maxCpuNs','maxDecodeWallNs']
protocol=json.loads((root/'protocol.json').read_text())
mode=sys.argv[1]; out=root/mode; out.mkdir()
images={str(p.relative_to(path)):digest(p) for p in sorted(path.rglob('*')) if p.is_file() and not p.is_symlink()}
assert images[protocol['fixturePath']] == protocol['fixtureSha256']
identity=digest(root/'protocol.json')
env={**os.environ,'NSUnbufferedIO':'YES'}
env['YL_AV1_VISIBLE_QUALIFICATION']='1'
env.pop('YL_TRIAL_LIMITS', None)
receipt={'product':images,'protocolSha256':identity,'run':mode}
if mode=='verification':
    before=json.loads((root/'baseline/receipt.json').read_text())
    assert before['product']==images and before['protocolSha256']==identity and before['passed']
    receipt['limitsSha256']=digest(root/'baseline/limits.json')
    env['YL_TRIAL_LIMITS']=(root/'baseline/limits.json').read_text()
save(out/'plan.json',receipt)
p=subprocess.Popen([str(binary)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,errors='replace')
receipt['pid']=p.pid
start=time.monotonic()
system=[];bad=[]; maxima=[0]*5; samples=[];ticks=[];decoded=[];end=False;ids=[]
with (out/'raw.log').open('x',buffering=1) as log:
    for line in p.stdout:
        log.write(line);s=line.strip()
        if 'QUAL_' not in s:continue
        s=s[s.index('QUAL_'):]
        parts=s.split()
        if parts[0]=='QUAL_ID':ids.append(parts[1:])
        if parts[0]=='QUAL_SAMPLE':samples.append((parts[1],int(parts[2])))
        if parts[0] in ('QUAL_SAMPLE','QUAL_END'):
            maxima=[max(a,int(b)) for a,b in zip(maxima,parts[-5:])]
        if parts[0]=='QUAL_DECODED':decoded.append(int(parts[1]))
        if parts[0]=='QUAL_SYSTEM':system.append(json.loads(s.split(' ',1)[1]))
        if parts[0]=='QUAL_DART':
            row=json.loads(s.split(' ',1)[1]);ticks.append(row)
        if parts[0]=='QUAL_FINISH':end=parts[-1]=='0'
        if parts[0] in ('QUAL_BAD','QUAL_ERROR','QUAL_DROP'):
            bad.append(s)
            # Failure invalidates the baseline. Keep the application's own disposal receipt when possible.
            if parts[0] != 'QUAL_ERROR':p.terminate()
code=p.wait()
if code or not end:bad.append('application did not complete successfully')
if not ids or any(x[0:2]!=['MacBookPro17,1','26A434'] or x[-1]!=str(mode=='verification').lower() for x in ids):bad.append('wrong decode identity or budget')
if not ticks or ticks[-1]['position'] < 1_200_000_000 or ticks[-1]['us'] < 1_200_000_000 or ticks[-1]['status']!='completed':bad.append('continuous playback incomplete')
if any(a['drops']!=0 or a['decoder']!='software' for a in ticks):bad.append('missing drop/mode evidence')
if max(decoded or [0])!=protocol['expectedVideoPackets']:bad.append('decoded frame count mismatch')
if len(samples)<500 or any(b[1]-a[1]>5_000_000_000 for a,b in zip(samples,samples[1:])):bad.append('resource sampling incomplete')
if not system or (system[-1].get('totalFrames') or 0)<protocol['expectedVideoPackets']-2 or any(x.get('droppedFrames') or x.get('corruptedFrames') for x in system):bad.append('system renderer output incomplete or dropped frames')
if any(x<=0 for x in maxima):bad.append('resource high-water marks incomplete')
if any(digest(path/n)!=h for n,h in images.items()):bad.append('built app changed during run')
receipt.update(passed=not bad,errors=bad,exit=code,elapsed=time.monotonic()-start,samples=len(samples),ticks=len(ticks),decoded=decoded,decoderIdentities=ids,peaks=dict(zip(names,maxima)))
save(out/'receipt.json',receipt)
if not bad:
    try:
        from macos_profile import observations
        observations(out, mode, protocol['expectedVideoPackets'])
        native=[l.strip().split('QUAL_NATIVE_THREADS ')[-1] for l in (out/'raw.log').read_text().splitlines() if 'QUAL_NATIVE_THREADS ' in l]
        if native!=['1']:raise ValueError('native single thread configuration not observed')
    except ValueError as err:
        bad.append(str(err));receipt.update(passed=False,errors=bad);save(out/'receipt.json',receipt)
if not bad and mode=='baseline':
    caps=protocol['trialCeilings']
    limits={n:min(caps[n],math.ceil(v*1.25/step)*step) for n,v,step in zip(names,maxima,[65536,1,4096,1000000,1000000])}
    limits['windowNs']=protocol['cpuWindowNs']
    save(out/'limits.json',limits)
print(mode,not bad,bad,flush=True)
sys.exit(bool(bad))
