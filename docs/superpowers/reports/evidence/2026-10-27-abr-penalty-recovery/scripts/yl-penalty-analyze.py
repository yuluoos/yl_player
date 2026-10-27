import json
from pathlib import Path
root=Path('/private/tmp/yl-penalty-20261027'); output=[]
for name in ['baseline','seek','reload','reload-repeat']:
 p=root/name
 if not (p/'receipt.json').exists():continue
 rows=[json.loads(x) for x in (p/'rows.jsonl').read_text().splitlines()]; receipt=json.loads((p/'receipt.json').read_text())
 attempts=[r['recoveryAttempt'] for r in rows if r.get('recoveryAttempt')]; a=attempts[0] if attempts else None
 high=[r for r in rows if a and r['elapsed']>a['elapsed'] and r['width']==640]
 frames=[r for prev,r in zip(rows,rows[1:]) if r['framesPublished']>prev['framesPublished']]
 before=[r for r in frames if a and r['elapsed']<a['elapsed']]; after=[r for r in frames if a and r['elapsed']>=a['elapsed']]
 sysfile=root/(name+'-system-log.json');logs=json.loads(sysfile.read_text()) if sysfile.exists() else []
 data={'name':name,'passed':receipt['passed'],'observation':receipt.get('observation'),'attempt':a,'firstPostActionHighElapsed':high[0]['elapsed'] if high else None,'firstPostActionHighPosition':high[0]['position'] if high else None,'sampledFrameGapAcrossAction':after[0]['elapsed']-before[-1]['elapsed'] if before and after else None,'largestPositionBackwardStep':min([r['position']-p['position'] for p,r in zip(rows,rows[1:])]),'maximumSampleGap':max(r['elapsed']-p['elapsed'] for p,r in zip(rows,rows[1:])),'finalPosition':rows[-1]['position'],'penaltyEvents':[{'timestamp':l['timestamp'],'message':l.get('eventMessage')} for l in logs if 'MoveAlternateToPenaltyBox' in l.get('eventMessage','')]}
 output.append(data)
(root/'analysis.json').write_text(json.dumps(output,indent=2)+'\n');print(json.dumps(output,indent=2))
