"""Qualify self-process heap captures using the shared CLOCK_MONOTONIC_RAW."""
import re
FIELDS=set('schemaVersion runId pid workload attempt phase edge monotonicUs'.split())
WINDOWS=((1,'live'),(2,'disposed'),(8,'disposed'))


def integer(v):return type(v) is int and 0<=v<=2**53-1


def validate_marker(m):
    if (not isinstance(m,dict) or set(m)!=FIELDS
        or type(m['schemaVersion']) is not int or m['schemaVersion']!=1
        or not isinstance(m['runId'],str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}',m['runId'])
        or not integer(m['pid']) or m['pid']==0
        or type(m['attempt']) is not int or (m['attempt'],m['phase']) not in WINDOWS
        or m['workload']!='playback' or m['edge'] not in ('begin','end')
        or not integer(m['monotonicUs'])):
        raise ValueError('Invalid lifetime checkpoint')


def validate_window(begin,end,probe):
    if begin is None or end is None:return False
    validate_marker(begin);validate_marker(end)
    if (begin['edge']!='begin' or end['edge']!='end' or end['monotonicUs']<=begin['monotonicUs']
        or any(begin[k]!=end[k] for k in ('runId','pid','attempt','phase','workload'))
        or any(probe.get(k)!=begin[k] for k in ('runId','pid','attempt','phase'))
        or not integer(probe.get('startedUs')) or not integer(probe.get('endedUs'))
        or probe['endedUs']<probe['startedUs']):
        raise ValueError('Mixed or invalid lifetime window')
    return (probe.get('status')=='captured' and
            begin['monotonicUs']<=probe['startedUs']<=probe['endedUs']<=end['monotonicUs'])
