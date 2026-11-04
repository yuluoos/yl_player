from pathlib import Path
from collections import Counter
import json,xml.etree.ElementTree as E,time,datetime
p=Path(__file__).parent/'http-clock-current-wait-traces/3'
toc=E.parse(p/'toc.xml').getroot();start=datetime.datetime.fromisoformat(next(toc.iter('start-date')).text).timestamp()-(time.time()-time.monotonic())
lines=(p/'raw.log').read_text().splitlines();drop=json.loads(next(l.split(' ',1)[1] for l in lines if l.startswith('QUAL_SCHEDULER ')))['hostNs']/1e9-start
root=E.parse(p/'time-profile.xml').getroot();ids={e.get('id'):e for e in root.iter() if e.get('id')}
def res(e):return ids[e.get('ref')] if e.get('ref') else e
rows=[]
for row in root.iter('row'):
 es=list(row)
 if es[6].tag!='tagged-backtrace':continue
 t=int(res(es[0]).text)/1e9
 stack=[res(f).get('name','?') for f in res(es[6]).findall('frame')]
 rows.append(dict(time=t,thread=res(es[1]).get('fmt'),state=res(es[4]).text,weight=int(res(es[5]).text),stack=stack))
near=[r for r in rows if drop-.45 <= r['time'] <=drop+.05]
(p/'near-drop-stacks.json').write_text(json.dumps(dict(approximateTraceStartHostSeconds=start,dropObservedTraceSeconds=drop,rows=near),indent=2)+'\n')
print('drop',drop,'range',min(r['time'] for r in rows),max(r['time'] for r in rows))
main=next(r['thread'] for r in rows if 'NSApplicationMain' in r['stack'])
for thread in sorted(set(r['thread'] for r in near)):
 selected=[r for r in near if r['thread']==thread]
 if thread==main or any(any('Yl' in s for s in r['stack']) for r in selected):
  print('THREAD',thread,'main',thread==main)
  for stack,n in Counter(tuple(r['stack']) for r in selected).most_common(4):
   ts=[r['time'] for r in selected if tuple(r['stack'])==stack]
   print(json.dumps(dict(samples=n,start=min(ts),end=max(ts),stack=stack[:18])))
