from pathlib import Path
import json,sys
sys.path.insert(0,'tool/playback_network')
from abr_accesslog import read_rows
from budget_exhaustion import summarize_budget_exhaustion
r=Path('/private/tmp/yl-triggered-downshift');p=r/'media/budget-zero';signals=read_rows(p/'signals.jsonl');cutoff=min(s['elapsed'] for s in signals)
rows=[v for v in read_rows(p/'rows.jsonl') if v['elapsed']<cutoff];frames=[v for v in read_rows(p/'frame-samples.jsonl') if v['elapsed']<=rows[-1]['elapsed']];decisions=[v for v in read_rows(p/'policy-decisions.jsonl') if v['elapsed']<=rows[-1]['elapsed']]
result=dict(firstSignalElapsed=cutoff,lastIncludedRow=rows[-1]['elapsed'],diagnosticPrefixOnly=True,fullCapturePassed=False,capabilityAccepted=False)
try:result['budgetObservation']=summarize_budget_exhaustion(rows,frames,decisions)
except ValueError as e:result['error']=str(e)
(r/'pre-interruption.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
