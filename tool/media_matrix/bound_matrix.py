"""Fixed-catalog public Flutter evidence. A matrix never certifies full P03."""
import base64
import json
from run_bound_android import parse_rows
from pathlib import Path
from bound_av import HASH, validate

IDS=set('mp4-avc-aac mov-hevc-aac mkv-avc-aac webm-vp9-opus flv-avc-mp3 ts-avc-ac3 ps-mpeg2-mp3 avi-avc-mp3 mkv-av1-opus mkv-avc-eac3 mkv-avc-dts mkv-avc-flac webm-vp9-vorbis mkv-hevc-main10-aac mkv-avc-ac3-51 mkv-avc-aac-no-cues mp4-truncated mkv-avc-opus mkv-avc-opus-silk mkv-avc-opus-hybrid mkv-avc-vorbis ps-avc-mp3'.split())

def catalog():
    return json.loads((Path(__file__).parent/'cases.json').read_text())['cases']

def cells(rows):
    """Keep every required, diagnostic and damaged input in both transports."""
    if len(rows)!=len(IDS) or {r['id'] for r in rows}!=IDS:
        raise ValueError('complete catalog identity missing or duplicated')
    return [dict(caseId=r['id'],transport=t,mediaHash=r['sha256'],
        requirement='corrupt' if r['integrity']=='truncated' else r['supportRequirement'])
        for r in rows for t in ('file','http')]

def planned_case(rows, case_id, platform, transport):
    """Select one immutable child; mono sources retain their actual channel map."""
    cells(rows)
    if platform not in ('macos','ios','android') or transport not in ('file','http'):
        raise ValueError('unsupported public matrix platform/transport')
    r=next(r for r in rows if r['id']==case_id)
    return dict(caseId=r['id'],file=r['file'],mediaHash=r['sha256'],transport=transport,
        sourceChannels=r['audio']['channels'],channels=2 if platform=='android' else r['audio']['channels'])

def extraction_valid(platform, record):
    """Replay Android's original byte stream, including malformed trailing data."""
    if platform!='android':return True
    try:
        raw=base64.b64decode(record['extractedJsonlBase64'],validate=True)
        rows,parsed=parse_rows(raw)
        return (type(record.get('extractExit')) is int and record['extractExit']==0 and
            parsed and rows==record.get('rows'))
    except (KeyError,ValueError,TypeError):return False

def summarize(matrix, records):
    """Replay raw child evidence; never trust cached pass booleans or drop failures.

    Each child is a separate run/session, bound to one frozen matrix/product.
    Diagnostics and corrupt inputs remain visible but never increase support.
    """
    if (not isinstance(matrix,dict) or matrix.get('platform') not in ('macos','ios','android') or
        not isinstance(matrix.get('matrixId'),str) or not matrix['matrixId'] or
        not isinstance(matrix.get('buildSha256'),str) or not HASH.fullmatch(matrix['buildSha256']) or
        not isinstance(records,list)):
        raise ValueError('invalid matrix identity or records')
    expected=cells(catalog())
    if matrix.get('schema')!=1 or matrix.get('cells')!=expected:
        raise ValueError('complete matrix coverage changed')
    seen=set();runs=set();out=[];errors=[];supported=0
    for record in records:
        if (not isinstance(record,dict) or not isinstance(record.get('cell'),dict) or
            not isinstance(record.get('plan'),dict) or not isinstance(record.get('status'),dict)):
            errors.append('invalid_child_record');continue
        cell=record.get('cell',{});key=(cell.get('caseId'),cell.get('transport'))
        if cell not in expected or key in seen:
            errors.append('duplicate_or_unplanned_cell');continue
        seen.add(key);p=record.get('plan',{});status=record.get('status',{})
        raw=validate(p,record.get('rows',[]))
        identity=(p.get('artifactKind')==('android-public-flutter-debug-apk' if matrix['platform']=='android' else 'apple-public-flutter-debug-app') and p.get('matrixId')==matrix['matrixId'] and p.get('platform')==matrix['platform'] and
            p.get('buildSha256')==matrix['buildSha256'] and p.get('testSha256')==matrix['buildSha256'] and
            p.get('planned')==[planned_case(catalog(),key[0],matrix['platform'],key[1])] and
            p.get('runId') not in runs and bool(p.get('runId')) and status.get('runId')==p.get('runId'))
        runs.add(p.get('runId'))
        extraction=extraction_valid(matrix['platform'],record)
        collector=(type(record.get('exitCode')) is int and record['exitCode']==0 and
            not record.get('collectorError') and extraction)
        passed=(collector and identity and raw['scopeAcceptance'] and status.get('passed') is True and
            status.get('identityVerified') is True and status.get('artifactsUnchanged') is True and
            record.get('artifactsUnchanged') is True)
        supported+=int(passed and cell['requirement']=='required')
        out.append(dict(**cell,accepted=bool(passed),identityBound=bool(identity),collectorPassed=bool(collector),extractionValid=bool(extraction),exitCode=record.get('exitCode'),rawErrors=raw['errors'],
            failure=status.get('failure'),collectorError=record.get('collectorError'),runId=p.get('runId')))
    missing=[c for c in expected if (c['caseId'],c['transport']) not in seen]
    return dict(schema=1,matrixId=matrix['matrixId'],platform=matrix['platform'],buildSha256=matrix['buildSha256'],
        requiredRows=40,supportedRows=supported,diagnosticRows=2,corruptRows=2,attemptedRows=len(seen),
        formatScopeAcceptance=supported==40 and not missing and not errors and matrix.get('artifactFinalVerified') is True,fullAcceptance=False,
        errors=errors,missing=missing,rows=out)
