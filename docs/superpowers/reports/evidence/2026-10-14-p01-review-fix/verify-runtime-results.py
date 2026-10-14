import sys,json,subprocess,hashlib
from pathlib import Path
root=Path.cwd(); platform=sys.argv[1]
sys.path.insert(0,str(root/'tool/consumer_fixtures/apple_flutter'))
import main_example_tests as m
result=Path('/private/tmp/p01-family-'+platform+'-final.xcresult')
out=Path('/private/tmp/p01-family-'+platform+'-runtime')
expected={x for x in m.expected_identities(root/'tool/consumer_fixtures/apple_flutter',platform) if x.startswith(('YlDashSampleSourceNativeTests/','YlDashProgramNativeTests/'))}
assert len(expected)==29,len(expected)
m.verify_result_bundle(root,result,platform,out,expected)
diag=Path('/private/tmp/p01-family-'+platform+'-diagnostics')
subprocess.run(['xcrun','xcresulttool','export','diagnostics','--path',str(result),'--output-path',str(diag)],check=True,stdout=subprocess.DEVNULL)
logs=list(diag.rglob('*StandardOutputAndStandardError*'))
assert logs,diag
text='\n'.join(p.read_text(errors='replace') for p in logs)
sys.path.insert(0,str(root/'tool/dash_timeline'))
from joint_observations import decode_records,summarize,check_limits
records=decode_records(text); assert len(records)==15,len(records)
rows=Path('/private/tmp/p01-family-'+platform+'-rows.jsonl');rows.write_text('\n'.join(json.dumps(x,separators=(',',':')) for x in records)+'\n')
stats=summarize(records);check_limits(stats,json.loads((root/'tool/dash_timeline/joint_acceptance.json').read_text())[platform])
Path('/private/tmp/p01-family-'+platform+'-statistics.json').write_text(json.dumps({'summary':stats,'frozenGate':{'passed':True}},indent=2)+'\n')
print('Frozen AV/gap envelope passed; max deltaUs:',max(v['deltaUs']['absoluteMaximum'] for v in stats.values()))
