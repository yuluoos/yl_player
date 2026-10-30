from pathlib import Path
import json,hashlib,subprocess
r=Path('/private/tmp/yl-triggered-downshift');captured=json.loads((r/'capture-source-identity.json').read_text());final=json.loads((r/'source-identity.json').read_text())
for name in captured:
 if captured[name]==final[name]:continue
 s=Path(name).read_text()
 if name.endswith('README.md'):s=subprocess.check_output(['git','show','c7342f8c:'+name]).decode()
 elif name.endswith('abr_accesslog.py'):
  a=s.index('def close_fixture(');b=s.index('def run(args):',a);s=s[:a]+s[b:]
  s=s.replace("        if fault_rate is not None and profile.steps[-1]['atMs']>15000:\n            raise ValueError('triggered fault requires an initial-only static profile')\n",'')
  s=s.replace('            from triggered_fault import TriggeredShaper,ControlServer\n',"            from triggered_fault import TriggeredShaper,ControlServer\n            if profile.steps[-1]['atMs']>15000:raise ValueError('triggered fault requires an initial-only static profile')\n")
  s=s.replace('        close_fixture(server,thread)','        if server:server.shutdown();server.server_close()')
  s=s.replace('        if log:log.close()','        if thread:thread.join(timeout=5)\n        if log:log.close()')
 elif name.endswith('/triggered_fault.py'):
  a=s.index("    low=next(");b=s.index('    return dict(bound=True',a);s=s[:a]+s[b:]
  s=s.replace(",secondDownshiftElapsed=low['elapsed']",'').replace('The trigger is bound to a high baseline and later progressing low frames in the same generation; exhausted windows and recovery still require the unchanged strict media validators.','A bound high baseline starts the fault; second downshift, exhausted windows and recovery still require the unchanged strict media validators.')
 elif name.endswith('test_triggered_fault.py'):
  s=s.replace('from http.server import HTTPServer,BaseHTTPRequestHandler\nimport threading\nimport abr_accesslog\n','')
  s=s.replace('        high_only=list(frames)\n','').replace("        frames.extend(dict(elapsed=t,generation=1,frames=1,width=320,position=t-3,rate=1,itemStatus=1,resumeSeekPending=False) for t in (43,44))\n",'')
  s=s.replace("        with self.assertRaises(ValueError):fault.summarize_trigger(self.shaper.snapshot(),client,rows,high_only)\n",'')
  a=s.index('\n    def test_unstarted_fixture_cleanup');s=s[:a]
 assert hashlib.sha256(s.encode()).hexdigest()==captured[name],name
 p=r/'capture-source-files'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
 print('hash-matched capture source',name)
