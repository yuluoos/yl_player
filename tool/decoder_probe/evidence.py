"""Conservative classification of the fixed owned Apple decoder probe matrix.

Decode evidence is not product support, output quality or a software budget.
"""
CASES = ('avc-control', 'av1-main8', 'av1-main10')
POLICIES = ('systemDefault', 'hardwarePreferred', 'hardwareRequired')
FIELDS = set(('caseId policy generation hardwareHint createStatus propertyStatus '
              'hardwareEvidence decodeStatus finishStatus waitStatus callbackErrors '
              'outputFrames expectedFrames geometryErrors pixelFormats').split())


def decoded(row):
    return (all(row[k] == 0 for k in ('createStatus', 'propertyStatus', 'decodeStatus',
                                    'finishStatus', 'waitStatus', 'callbackErrors', 'geometryErrors'))
            and row['hardwareEvidence'] == 'hardware'
            and row['outputFrames'] == row['expectedFrames'])


def summarize(rows):
    expected = {(c, p, g) for c in CASES for p in POLICIES for g in range(2)}
    seen = set()
    for r in rows:
        if not isinstance(r, dict) or set(r) != FIELDS:
            raise ValueError('Invalid decoder observation')
        key = (r['caseId'], r['policy'], r['generation'])
        if type(r['generation']) is not int or key not in expected or key in seen:
            raise ValueError('Incomplete or duplicate decoder matrix')
        seen.add(key)
        if type(r['hardwareHint']) is not bool or r['hardwareEvidence'] not in ('unknown', 'software', 'hardware'):
            raise ValueError('Invalid hardware evidence')
        for k in ('createStatus', 'propertyStatus', 'decodeStatus', 'finishStatus', 'waitStatus'):
            v = r[k]
            if not (type(v) is int and -(2**31) <= v < 2**31 or v is None and k != 'createStatus'):
                raise ValueError('Invalid decoder status')
        for k in ('callbackErrors', 'outputFrames', 'expectedFrames', 'geometryErrors'):
            if type(r[k]) is not int or not 0 <= r[k] <= 1024:
                raise ValueError('Invalid frame count')
        if r['expectedFrames'] == 0 or not isinstance(r['pixelFormats'], list) or len(r['pixelFormats']) > 16:
            raise ValueError('Invalid output metadata')
        if any(not isinstance(v, str) or len(v) != 4 or not v.isascii() or not v.isalnum() for v in r['pixelFormats']):
            raise ValueError('Invalid pixel format')
    if seen != expected:
        raise ValueError('Incomplete decoder matrix')
    if not all(decoded(r) for r in rows if r['caseId'] == 'avc-control'):
        raise ValueError('Positive control did not decode completely in hardware')
    av1 = [r for r in rows if r['caseId'] != 'avc-control']
    return dict(observations=len(rows), av1HardwareDecodeObservations=sum(decoded(r) for r in av1),
                av1UnavailableObservations=sum(r['createStatus'] == -12906 for r in av1),
                av1SessionCreationFailures=sum(r['createStatus'] != 0 for r in av1),
                productionEnabled=False, softwareBudget='unmeasured_not_admitted',
                physicalOutput='not_verified', otherDevices='not_verified')
