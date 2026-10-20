"""Same-host-clock compositor observations; never physical scanout or A/V sync."""
from performance_gate import integer, require

# Frozen acquisition correctness parameters, not performance SLOs.
FRAME_US=100000
TARGET_TOLERANCE_US=200000
STABLE_WINDOW_US=1000000
MAX_GAP_US=250000


def measure(trial, rows):
    start,seek,target=trial['startUs'],trial['seekStartUs'],trial['targetUs']
    require(integer(start) and (seek is None or integer(seek) and seek>=start) and integer(target))
    require(isinstance(rows,list) and len(rows)<=8192)
    previous=None
    for row in rows:
        require(set(row)=={'displayUs','receivedUs','frame'})
        require(integer(row['displayUs']) and integer(row['receivedUs']) and row['receivedUs']>=row['displayUs'])
        require(previous is None or row['displayUs']>previous)
        require(row['frame'] is None or integer(row['frame'],0,119))
        previous=row['displayUs']
    blank=[r for r in rows if r['displayUs']<start]
    require(bool(blank) and blank[-1]['frame'] is None)
    load=[r for r in rows if r['displayUs']>=start and (seek is None or r['displayUs']<seek)
          and r['frame'] is not None and r['frame']<=10]
    first=load[0]['displayUs']-start if load else None
    near=None;stable=None;window=None;previous=None
    for row in rows if seek is not None else []:
        time=row['displayUs'];frame=row['frame']
        if time<seek:continue
        if frame is None:
            window=None;previous=None;continue
        position=frame*FRAME_US
        if near is None:
            if abs(position-target)>TARGET_TOLERANCE_US:continue
            near=time
        if previous is not None and (time-previous['displayUs']>MAX_GAP_US or frame<previous['frame']):window=None
        if window is not None:
            elapsed=time-window['displayUs'];advance=(frame-window['frame'])*FRAME_US
            if abs(advance-elapsed)>TARGET_TOLERANCE_US: window=None
            elif elapsed>=STABLE_WINDOW_US:
                stable=time;break
        if window is None:window=row
        previous=row
    return dict(firstCompositorUs=first,seekFirstCompositorUs=None if near is None else near-seek,
        seekStableCompositorUs=None if stable is None else stable-seek)
