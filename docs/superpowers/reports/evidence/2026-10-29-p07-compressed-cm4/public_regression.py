from pathlib import Path
import gzip,io,json
from stream_inventory import inspect
r=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player');out=Path('/private/tmp/yl-p07-cm4');base=Path.cwd()/'docs/superpowers/reports/evidence/2026-10-29-p07-cm-frame-provenance';results=[]
for name,media,sha in [('p5',r/'.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes/sol-levante-p5-1080p.mp4','87fe0115f3002a621d2380a9f91852ef91a15854a446efe26de8744f77ef5346'),('fel',r/'.superpowers/sdd/2026-10-20-p07-public-resources/resources/fel-test-st-dl-p7-cmv4-v4.mp4','419fc183988cb57b0cac2907a01d9f43b1a5ec34012b4c0655574d77678ee4fa')]:
 trace=io.BytesIO();summary=inspect(media,sha,out/'patched/target/release/yl-dovi-stream-inspector',include_layers=True,include_dm_blocks=True,trace_sink=trace)
 old=[json.loads(line) for line in gzip.decompress((base/(name+'-decoded.jsonl.gz')).read_bytes()).splitlines()]
 new=[json.loads(line) for line in trace.getvalue().splitlines()]
 assert [{k:v for k,v in row.items() if k not in ('base','enhancement')} for row in old]==new
 results.append({'name':name,'frames':len(new),'metadata_exactly_matches_previous_decoded_trace':True,'summary':summary});print(name,len(new),'all metadata matches',flush=True)
(out/'public-regression.json').write_text(json.dumps(results,indent=2)+'\n')
