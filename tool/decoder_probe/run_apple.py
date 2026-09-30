"""Collect a fixed decoder feasibility matrix; no product admission or SLO."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from evidence import summarize

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def collect(output):
    # Never overwrite an earlier run, including failed or incomplete evidence.
    output.mkdir(parents=True, exist_ok=False)
    rows = []
    result = {'schemaVersion': 1, 'runStatus': 'failed', 'stage': 'fixture_validation',
              'productionEnabled': False, 'softwareBudget': 'unmeasured_not_admitted'}
    try:
        manifest = json.loads((HERE/'fixtures/manifest.json').read_text())
        assert [r['caseId'] for r in manifest['cases']] == ['avc-control', 'av1-main8', 'av1-main10']
        for row in manifest['cases']:
            path = HERE/'fixtures'/(row['caseId']+'.json')
            assert path.name == row['fixture'] and digest(path) == row['sha256']
            assert digest(ROOT/row['ownedSource']) == row['ownedSourceSha256']
        source = HERE/'apple_decode_probe.swift'
        result.update(baseCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            sourceFingerprints={str(p.relative_to(ROOT)): digest(p) for p in
                [source,HERE/'run_apple.py',HERE/'evidence.py',HERE/'fixtures/manifest.json']},
            fixtures=manifest['cases'], host=dict(
                model=subprocess.check_output(['sysctl','-n','hw.model'],text=True).strip(),
                cpu=subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),
                os=subprocess.check_output(['sw_vers','-productVersion'],text=True).strip(),
                osBuild=subprocess.check_output(['sw_vers','-buildVersion'],text=True).strip()))
        result['stage'] = 'build'
        with (output/'build.log').open('w') as log:
            subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(output/'cache'),str(source),'-o',str(output/'probe')],
                           stdout=log,stderr=log,timeout=120,check=True)
        result['binarySha256'] = digest(output/'probe')
        result['stage'] = 'decode'
        for fixture in manifest['cases']:
            case = fixture['caseId']
            with (output/(case+'.jsonl')).open('w') as raw, (output/(case+'.stderr')).open('w') as errors:
                subprocess.run([str(output/'probe'),str(HERE/'fixtures'/(case+'.json'))],
                               stdout=raw,stderr=errors,timeout=30,check=True)
            parsed=[json.loads(line) for line in (output/(case+'.jsonl')).read_text().splitlines()]
            assert all(r['caseId']==case and r['expectedFrames']==fixture['frames'] for r in parsed)
            rows.extend(parsed)
        result['stage'] = 'classification'
        result['summary'] = summarize(rows)
        result.update(runStatus='collected', stage='complete')
    except (AssertionError, ValueError, OSError, subprocess.SubprocessError):
        # Raw partial files remain. No incomplete run produces a support summary.
        pass
    finally:
        result['observations'] = rows
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['runStatus']=='collected'


def main():
    if len(sys.argv)!=2:
        print('Usage: python3 -B tool/decoder_probe/run_apple.py NEW_OUTPUT_DIRECTORY',file=sys.stderr)
        return 2
    try: success=collect(Path(sys.argv[1]).resolve())
    except OSError:
        print('A new writable output directory is required.',file=sys.stderr);return 2
    print('Decoder evidence collected; product support and budgets remain unaccepted.' if success
          else 'Decoder evidence incomplete; inspect the retained result and raw logs.')
    return 0 if success else 2

if __name__=='__main__': sys.exit(main())
