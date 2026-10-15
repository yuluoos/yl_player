"""Summarize a frozen player-output plan without shrinking its denominator.

Callers retain raw captures/native PCM records with the same run and installed
build identity. This validator checks that evidence's structure/provenance; it
cannot turn a boolean, host decoder or another run into player-output evidence.
"""
import re

_HASH = re.compile(r'[0-9a-f]{64}\Z')
_TRANSPORTS = {'file', 'http', 'renamed-file', 'wrong-known-file', 'extensionless-file', 'renamed-http'}


def summarize(plan: dict, rows: list[dict], cases: list[dict]) -> dict:
    """Count required support, negative controls and diagnostics separately.

    `plan` is frozen before execution, including runId, buildSha256, platform and
    planned caseId/transport pairs. Catalog classification must already pass
    catalog.validate_case. Missing/skipped/duplicate rows cannot reduce coverage.
    PCM from a separate native run must be reported separately, never spliced in.
    """
    errors = set()
    result = dict(fullAcceptance=False, playerOutputVerified=False, requiredRows=0,
                  supportedRows=0, diagnosticRows=0, negativeControls=0, errors=[])
    if not isinstance(plan, dict) or not isinstance(rows, list) or not isinstance(cases, list):
        result['errors'] = ['invalid_envelope']; return result
    catalog = {c['id']: c for c in cases}
    if len(catalog) != len(cases): errors.add('duplicate_catalog')
    if not isinstance(plan.get('runId'), str) or not plan['runId'].strip(): errors.add('invalid_run')
    if not isinstance(plan.get('buildSha256'), str) or not _HASH.fullmatch(plan['buildSha256']): errors.add('invalid_build')
    if plan.get('platform') not in ('android', 'ios', 'macos'): errors.add('invalid_platform')
    expected = set()
    planned = plan.get('planned')
    if not isinstance(planned,list) or not planned: errors.add('empty_plan'); planned=[]
    for item in planned:
        key = (item.get('caseId'), item.get('transport'))
        if key in expected: errors.add('duplicate_plan')
        expected.add(key)
        if key[0] not in catalog or key[1] not in _TRANSPORTS: errors.add('invalid_plan'); continue
        case=catalog[key[0]]
        if case['supportRequirement']=='diagnostic': result['diagnosticRows'] += 1
        elif case['integrity']=='truncated': result['negativeControls'] += 1
        else: result['requiredRows'] += 1
    seen=set(); verified_controls=0
    for row in rows:
        if not isinstance(row,dict): errors.add('invalid_row'); continue
        key=(row.get('caseId'),row.get('transport'))
        if key in seen: errors.add('duplicate_row'); continue
        seen.add(key)
        if key not in expected or key[0] not in catalog: errors.add('unplanned_row'); continue
        case=catalog[key[0]]
        identity_ok = all(row.get(k)==plan.get(k) for k in ('runId','buildSha256','platform'))
        identity_ok &= row.get('mediaHash')==case['sha256'] and row.get('supportRequirement')==case['supportRequirement']
        if not identity_ok: errors.add('identity_mismatch'); continue
        if case['supportRequirement']=='diagnostic': continue
        if case['integrity']=='truncated':
            if (row.get('outcome')=='failed' and row.get('firstFrame') is False and
                row.get('category') in ('source','container') and row.get('disposed') is True): verified_controls+=1
            else: errors.add('negative_control_failed')
            continue
        lifecycle = row.get('outcome')=='passed' and all(row.get(k) is True for k in ('firstFrame','seekProgress','completed','disposed'))
        output = (row.get('pixelMarkersVerified') is True and row.get('pcmMarkersVerified') is True and
                  row.get('pixelVerificationMethod') in ('player-composition','native-player-pixels') and
                  row.get('pcmVerificationMethod')=='native-player-pcm' and
                  type(row.get('audioClockUs')) is int and row['audioClockUs']>=0)
        if lifecycle and output: result['supportedRows']+=1
        else: errors.add('required_output_unverified')
    if seen != expected: errors.add('incomplete_rows')
    result['playerOutputVerified'] = not errors and result['requiredRows']>0 and result['supportedRows']==result['requiredRows']
    result['fullAcceptance'] = result['playerOutputVerified'] and verified_controls==result['negativeControls']
    result['errors']=sorted(errors)
    return result
