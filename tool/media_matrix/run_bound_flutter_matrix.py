#!/usr/bin/env python3
"""Run every catalog file/managed-HTTP cell against one frozen public product.

Independent child runs isolate unsupported formats. Every result and exception is
retained. Neither diagnostics nor unavailable hardware reduces the denominator.
"""
import argparse
import base64
import gzip
import json
import subprocess
import sys
import uuid
from pathlib import Path
from bound_artifacts import freeze, sha_file, verify
from bound_matrix import catalog, cells, summarize
from run_bound_apple import write


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform',choices=['macos','ios','android'],required=True)
    parser.add_argument('--app',type=Path)
    parser.add_argument('--apk',type=Path)
    parser.add_argument('--serial')
    target=parser.add_mutually_exclusive_group()
    target.add_argument('--simulator')
    target.add_argument('--device')
    parser.add_argument('--flutter',default='flutter')
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    android=args.platform=='android'
    if android and (not args.apk or not args.serial):parser.error('--apk and --serial required')
    if not android and not args.app:parser.error('--app required')
    if args.platform=='ios' and not (args.simulator or args.device):parser.error('--simulator or --device required')
    if args.platform!='ios' and (args.simulator or args.device):parser.error('iOS target required')
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
    product={'sha256':sha_file(args.apk)} if android else freeze(args.app.resolve(),True)
    def stable():return sha_file(args.apk)==product['sha256'] if android else verify(args.app.resolve(),product)
    matrix=dict(schema=1,matrixId=str(uuid.uuid4()),platform=args.platform,buildSha256=product['sha256'],cells=cells(catalog()),artifactFinalVerified=False)
    write(out/'matrix-plan.json',matrix);write(out/'product-files.json',product)
    records=[];progress_supported=0
    for index,cell in enumerate(matrix['cells']):
        folder=out/(cell['caseId']+'-'+cell['transport'])
        command=[sys.executable,'-B',str(Path(__file__).with_name('run_bound_flutter_android.py' if android else 'run_bound_flutter_apple.py')),
            '--out',str(folder),'--case',cell['caseId'],'--transport',cell['transport'],'--matrix-id',matrix['matrixId']]
        command+=['--apk',str(args.apk.resolve()),'--serial',args.serial] if android else ['--app',str(args.app.resolve()),'--platform',args.platform]
        if args.simulator:command+=['--simulator',args.simulator]
        if args.device:command+=['--device',args.device,'--flutter',args.flutter]
        record=dict(cell=cell,plan={},rows=[],status={},artifactsUnchanged=False)
        try:
            with (out/(folder.name+'.log')).open('w') as log:
                completed=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=600 if args.device else 240)
            record['exitCode']=completed.returncode
            for key in ('plan','status'):record[key]=json.loads((folder/(key+'.json')).read_text())
            record['rows']=json.loads(gzip.decompress((folder/'rows.json.gz').read_bytes()))
            if android:
                record['extractedJsonlBase64']=base64.b64encode(gzip.decompress((folder/'extracted.jsonl.gz').read_bytes())).decode()
                record['extractExit']=json.loads((folder/'extraction.json').read_text())['exitCode']
            record['artifactsUnchanged']=stable()
        except Exception as error:record['collectorError']=str(error)
        records.append(record)
        # Progress is explicitly provisional. Validate this child once here;
        # independently replay every retained raw child for final acceptance.
        progress_supported+=summarize(matrix,[record])['supportedRows']
        write(out/'matrix-progress.json',dict(provisional=True,attemptedRows=len(records),
            requiredRows=40,supportedRows=progress_supported,formatScopeAcceptance=False,fullAcceptance=False))
        print(f"{index+1}/44 {folder.name}: {progress_supported}/40 required supported",flush=True)
        # A changed bundle invalidates the matrix; never run more cells under a
        # different product while claiming the frozen build identity.
        if not stable():break
    matrix['artifactFinalVerified']=stable();write(out/'matrix-plan.json',matrix)
    summary=summarize(matrix,records);write(out/'matrix-result.json',summary)
    with gzip.open(out/'records.json.gz','wb') as stream:stream.write(json.dumps(records,sort_keys=True).encode())
    print(json.dumps({k:v for k,v in summary.items() if k!='rows'},indent=2))
    return 0 if summary['formatScopeAcceptance'] else 1

if __name__=='__main__':raise SystemExit(main())
