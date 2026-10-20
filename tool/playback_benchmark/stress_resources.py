"""Join actual self-process observations to the same frozen playback trials."""
import copy
from performance_gate import validate_run
from resources import summarize_trials, summarize_disposed_memory


def attach(run, trials):
    validate_run(run)
    summary=summarize_trials(trials)
    if len(trials)!=run['plannedAttempts']: raise ValueError('incomplete resources')
    for playback,resource in zip(run['trials'],trials):
        if (resource['runId']!=run['runId'] or resource['buildMode']!=run['conditions']['buildMode'] or
            resource['attempt']!=playback['attempt'] or resource['outcome']!=playback['outcome']):
            raise ValueError('resource identity mismatch')
    summary['disposed']=summarize_disposed_memory(trials)
    result=copy.deepcopy(run)
    definitions={'cpuPlayingPercent':'percent','rssPeakBytes':'bytes','footprintPeakBytes':'bytes',
                 'rssDisposedBytes':'bytes','footprintDisposedBytes':'bytes'}
    if set(definitions)&set(run['metrics']): raise ValueError('resource metric collision')
    result['metrics'].update({name:dict(unit=unit,boundary='process-sample') for name,unit in definitions.items()})
    for playback,resource,statistics in zip(result['trials'],trials,summary['trials']):
        playing=statistics['phases'].get('playing',{})
        values=playback['values']
        values['cpuPlayingPercent']=playing.get('cpuOneCorePercent',{}).get('weightedMean')
        for field,peak,disposed in [('rssBytes','rssPeakBytes','rssDisposedBytes'),
                                    ('footprintBytes','footprintPeakBytes','footprintDisposedBytes')]:
            observed=[r[field] for r in resource['samples'] if r[field] is not None]
            values[peak]=max(observed) if observed else None
            endings=[r[field] for r in resource['samples'] if r['phase']=='disposed']
            values[disposed]=endings[-1] if endings else None
    for field in ('power','thermal'):
        observed={r[field] for t in trials for r in t['samples']}
        result['conditions'][field]=next(iter(observed)) if len(observed)==1 else 'unknown'
    validate_run(result)
    return result,summary
