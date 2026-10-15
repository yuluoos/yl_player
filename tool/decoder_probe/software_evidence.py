"""Validate fixed P03 process measurements; never manufacture admission profiles.

Units are bytes and nanoseconds. CPU is cumulative *process* CPU, including
internal workers and unrelated process activity, not outer decode-thread time.
The short engineering protocol cannot establish sustained thermal qualification.
"""
import re
import hashlib
import json

_MAX = 2**63 - 1
_HASH = re.compile(r'[0-9a-f]{64}\Z')
_FIXED = dict(schemaVersion=1, repetitions=5, idleNs=2_000_000_000,
              decodeNs=12_000_000_000, disposeNs=2_000_000_000,
              sampleIntervalNs=250_000_000)


def _integer(value, minimum=0, maximum=_MAX):
    return type(value) is int and minimum <= value <= maximum


def _key_valid(key):
    if not isinstance(key, dict):
        return False
    if any(not isinstance(key.get(k),str) or not key[k].strip()
           for k in ('model','osBuild','decoderBuild')):
        return False
    if not _HASH.fullmatch(key['decoderBuild']):
        return False
    fields = ('width','height','fpsNumerator','fpsDenominator','threads',
              'outputPixelFormat','codec')
    if any(not _integer(key.get(k),1) for k in fields):
        return False
    if not _integer(key.get('profile')) or type(key.get('bitDepth')) is not int or key.get('bitDepth') not in (8,10,12):
        return False
    if type(key.get('chroma')) is not int or key.get('chroma') not in (400,420,422,444):
        return False
    return key['width']*key['height']*8 <= _MAX


def summarize(protocol: dict, rows: list[dict]) -> dict:
    """Return measured peaks and explicit blockers; no files or profiles are written.

    Protocol values must match the predeclared 5-process/16-second/250-ms
    engineering run. Every planned sample and output control is mandatory.
    Sustained qualification and independent verification require separate,
    content-addressed evidence; a caller-supplied boolean is insufficient.
    """
    errors = set()
    result = dict(measurementValid=False, productionEligible=False,
                  admissionBlockers=[], measurementErrors=[])
    if not isinstance(protocol,dict) or not isinstance(rows,list):
        result['measurementErrors']=['invalid_envelope']
        result['admissionBlockers']=['measurement_invalid']
        return result
    if any(type(protocol.get(k)) is not int or protocol[k]!=v for k,v in _FIXED.items()):
        errors.add('protocol_mismatch')
    protocol_hash=hashlib.sha256(json.dumps(protocol,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    key=protocol.get('key')
    if not _key_valid(key): errors.add('invalid_key')
    if not isinstance(protocol.get('fixtureSha256'),str) or not _HASH.fullmatch(protocol['fixtureSha256']):
        errors.add('invalid_fixture_hash')
    if protocol.get('buildMode') not in ('release','debug') or type(protocol.get('simulator')) is not bool:
        errors.add('unknown_environment')
    if len(rows)!=5: errors.add('incomplete_runs')
    indices=set(); identities=set(); raw_hashes=set(); peak_rss=peak_footprint=peak_cpu=0
    for row in rows:
        if not isinstance(row,dict):
            errors.add('invalid_row');continue
        if row.get('protocolSha256')!=protocol_hash:errors.add('protocol_hash_mismatch')
        index=row.get('run')
        if not _integer(index,0,4) or index in indices: errors.add('invalid_run_index')
        else: indices.add(index)
        run_id=row.get('runId'); raw=row.get('rawSha256')
        if not isinstance(run_id,str) or not run_id or run_id in identities: errors.add('duplicate_process')
        else: identities.add(run_id)
        if not isinstance(raw,str) or not _HASH.fullmatch(raw) or raw in raw_hashes: errors.add('invalid_raw_identity')
        else: raw_hashes.add(raw)
        for field in ('key','fixtureSha256','buildMode','simulator'):
            if row.get(field)!=protocol.get(field):errors.add('environment_or_input_mismatch')
        if row.get('status')!='passed' or row.get('outputMarkersVerified') is not True or row.get('positiveControlPassed') is not True:
            errors.add('output_or_control_failed')
        if _key_valid(key):
            numerator=key['fpsNumerator']*12;denominator=key['fpsDenominator']
            if numerator%denominator or type(row.get('decodedFrames')) is not int or row['decodedFrames']!=numerator//denominator:
                errors.add('incomplete_output')
        samples=row.get('samples')
        if not isinstance(samples,list) or len(samples)!=65:
            errors.add('incomplete_samples');continue
        previous_cpu=None;first_cpu=None
        for position,sample in enumerate(samples):
            if not isinstance(sample,dict):errors.add('invalid_sample');continue
            clock=sample.get('monotonicNs');cpu=sample.get('cpuNs')
            if not _integer(clock) or clock!=position*250_000_000:errors.add('nonmonotonic_or_missing_sample')
            if not _integer(cpu) or (previous_cpu is not None and cpu<previous_cpu):
                errors.add('invalid_cpu_counter')
            else:
                if first_cpu is None:first_cpu=cpu
                previous_cpu=cpu;peak_cpu=max(peak_cpu,cpu-first_cpu)
            for field in ('rssBytes','footprintBytes'):
                if not _integer(sample.get(field),1):errors.add('invalid_memory_counter')
            if _integer(sample.get('rssBytes'),1):peak_rss=max(peak_rss,sample['rssBytes'])
            if _integer(sample.get('footprintBytes'),1):peak_footprint=max(peak_footprint,sample['footprintBytes'])
            if sample.get('thermal')!='nominal' or sample.get('lowPower') is not False:
                errors.add('unknown_or_constrained_power')
    if indices!=set(range(5)):errors.add('incomplete_runs')
    blockers=['sustained_thermal_missing','independent_verification_missing']
    if errors:blockers.insert(0,'measurement_invalid')
    if protocol.get('buildMode')!='release':blockers.append('non_release_build')
    if protocol.get('simulator') is not False:blockers.append('simulator')
    result.update(measurementValid=not errors, admissionBlockers=blockers,
                  measurementErrors=sorted(errors), peakRSSBytes=peak_rss,
                  peakFootprintBytes=peak_footprint, peakProcessCpuNs=peak_cpu)
    return result
