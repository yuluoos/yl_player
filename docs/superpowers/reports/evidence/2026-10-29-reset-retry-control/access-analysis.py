from pathlib import Path
import json
r=Path('/private/tmp/yl-reset-retry-control');result={}
for n in ('budget-throttle','budget-mild','normal','budget-late-throttle','budget-late-mild'):
 p=r/'media'/n
 if not (p/'receipt.json').exists():continue
 rows=[json.loads(x) for x in (p/'rows.jsonl').read_text().splitlines() if x.strip()]
 changes=[];last=None
 for row in rows:
  signature=(row['width'],row['errorLogEventCount'],row['automaticAttempts'],len(row['logs']),tuple(v['indicatedBitrate'] for v in row['logs']))
  if signature!=last:
   changes.append({k:row[k] for k in ['elapsed','position','width','errorLogEventCount','automaticAttempts','logs']});last=signature
 last_install=max((e['elapsedAfter'] for e in rows[-1]['automaticEvents'] if e['outcome']=='installed'),default=0)
 late=[v for v in rows if v['elapsed']>=max(90,last_install)]
 result[n]=dict(transitions=changes,lateSampleCount=len(late),lateLogs=late[-1]['logs'] if late else [],lateErrorCounts=sorted(set(v['errorLogEventCount'] for v in late)),lateWidths=sorted(set(v['width'] for v in late)),
  interpretation='Native access-log bitrate values and transfer totals are observations, not an exposed AVPlayer ABR decision rule; no per-transfer rate inferred by subtracting logs across item replacement.')
(r/'access-analysis.json').write_text(json.dumps(result,indent=2)+'\n')
for n,d in result.items():print(n,'late widths',d['lateWidths'],'error counts',d['lateErrorCounts'],'last access log',d['lateLogs'][-1:])
