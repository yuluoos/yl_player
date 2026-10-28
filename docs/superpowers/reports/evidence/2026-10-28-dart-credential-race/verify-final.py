from pathlib import Path
import json,hashlib,re
r=Path('/private/tmp/yl-dart-credential-race');result={}
for platform in ['macos','ios']:
 name='final-'+platform;receipt=json.loads((r/(name+'-result.json')).read_text());log=(r/(name+'.log')).read_text();assert receipt['exitCode']==0 and receipt['testsPassed'];assert re.search(r'\+3: All tests passed!',log)
 cases={}
 for line in log.splitlines():
  if line.startswith('credential-race '):
   name,body=line[len('credential-race '):].split(': ',1);cases[name]=json.loads(body)
 assert set(cases)=={'manifest','media'}
 for name,case in cases.items():
  assert case['winnerFirstFrame'] and case['winnerProgressAfterRelease'] and case['winnerFreshRequestAfterOld'];t=case['trace']
  assert t.index('winner-committed')<t.index('old-released')<t.index('old-handler-completed')<t.index('winner-fresh-request-after-old')
  for request in case['requests']:
   flags=[request[k] for k in ['authorization','cookie','sessionCredential']]
   if request['origin']=='secondary' or request['path'].startswith('/returned/'):assert not any(flags)
   if request['load']=='winner' and request['path']=='/chunk-0-00003.m4s':assert all(flags)
 result[platform]=dict(passed=3,failed=0,cases=cases,logSha256=receipt['logSha256'])
identity=json.loads((r/'source-identity.json').read_text())
for p,h in identity.items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
(r/'final-evidence.json').write_text(json.dumps(dict(sourceFilesVerified=len(identity),platforms=result),indent=2)+'\n');print({k:v['passed'] for k,v in result.items()})
