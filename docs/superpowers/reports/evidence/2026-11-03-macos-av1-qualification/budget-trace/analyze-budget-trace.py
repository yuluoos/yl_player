from pathlib import Path
from collections import Counter
import json,xml.etree.ElementTree as E
p=Path('build/macos-av1-20261103-resumed/budget-trace');root=E.parse(p/'time-profile.xml').getroot();ids={e.get('id'):e for e in root.iter() if e.get('id')}
def resolve(e): return ids[e.get('ref')] if e.get('ref') else e
def frames(e): return [resolve(f).get('name','?') for f in resolve(e).findall('frame')]
counts=Counter();decode=[];times=[]
for row in root.iter('row'):
 es=list(row);t=int(resolve(es[0]).text);times.append(t)
 if es[6].tag!='tagged-backtrace': continue
 stack=frames(es[6]);state=resolve(es[4]).text;thread=resolve(es[1]).get('fmt');weight=int(resolve(es[5]).text)
 if any('SoftwareVideoDecoder.measured' in s for s in stack):
  counts[tuple(stack[:5])]+=1;decode.append(dict(timeNs=t,thread=thread,state=state,weight=weight,stack=stack))
summary=dict(rows=len(times),timeRangeNs=[min(times),max(times)],nativeSamples=len(decode),nativeStacks=[dict(samples=n,stack=list(s)) for s,n in counts.most_common()],nativeRows=decode)
(p/'native-stack-analysis.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({k:v for k,v in summary.items() if k!='nativeRows'},indent=2))
