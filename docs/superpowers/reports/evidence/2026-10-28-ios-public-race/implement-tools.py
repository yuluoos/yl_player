from pathlib import Path
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text();at='def public_policy_cycle(args):\n'
t='''def public_policy_race(args):
    enabled = getattr(args, 'public_policy_race', False)
    if type(enabled) is not bool or (enabled and (
            getattr(args, 'public_policy_cycle', False) or
            getattr(args, 'duration_seconds', 40) != 120 or
            getattr(args, 'direct_hls_control', False) or
            getattr(args, 'recovery_action', 'none') != 'auto-reload' or
            getattr(args, 'auto_scenario', 'normal') not in ('caps-during-preparation', 'fixed-during-preparation') or
            getattr(args, 'candidate_preparation', 'manifest-only') != 'asset-preroll' or
            getattr(args, 'startup_delay_ms', 0) != 0)):
        raise ValueError('public policy race requires owned 120s caps/fixed preroll diagnostic')
    return enabled


def summarize_public_race(rows, frames, policy):
    """Reject missing races: a naturally issued ticket and real command must win."""
    def require(value):
        if not value: raise ValueError('incomplete public host preparation race evidence')
    def finite(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    require(isinstance(rows, list) and len(rows) >= 4 and isinstance(frames, list))
    require(isinstance(policy, dict) and policy.get('triggerExercised') is True and
            all(type(policy.get(k)) is int and policy[k] == 1 for k in ('reservations', 'tickets', 'attempts')))
    require(all(isinstance(r, dict) and finite(r.get('elapsed')) for r in rows))
    require(all(a['elapsed'] < b['elapsed'] for a,b in zip(rows, rows[1:])))
    session = rows[0].get('sessionId'); scenario = rows[0].get('autoScenario')
    require(isinstance(session, str) and bool(session) and
            scenario in ('caps-during-preparation', 'fixed-during-preparation'))
    events = rows[-1].get('automaticEvents')
    require(isinstance(events, list) and len(events) == 1 and isinstance(events[0], dict))
    e = events[0]
    require(type(e.get('attempt')) is int and e['attempt'] == 1 and e.get('outcome') == 'preparationFailed')
    require(all(e.get(k) is True for k in ('publicCommandApplied', 'publicCommandItemChanged',
                                          'publicCommandReady', 'warmupDetached')))
    require(all(e.get(k) is False for k in ('publicCommandManuallyInvalidated',
                'warmupReusesPrerolledItem', 'warmupOldItemRetained')))
    require(e.get('publicCommandSessionId') == session and e.get('warmupOutcome') == 'cancelled' and
            e.get('warmupStage') == 'waitingReady' and e.get('freshPreparedItemInstalled') is not True)
    keys = ('due', 'elapsed', 'publicCommandStartedElapsed', 'publicCommandCompletedElapsed', 'elapsedAfter')
    require(all(finite(e.get(k)) for k in keys))
    require(all(e[a] <= e[b] for a,b in zip(keys,keys[1:])) and e['elapsedAfter'] <= rows[-1]['elapsed'])
    previous = 0
    for r in rows:
        require(r.get('publicPolicyRace') is True and r.get('publicPolicyCycle') is False and
                r.get('autoScenario') == scenario and r.get('sessionId') == session and
                r.get('hostFailureCount') == 0 and
                r.get('hostStatus') in ('loading', 'ready', 'playing', 'paused', 'buffering', 'completed'))
        budget = r.get('automaticAttempts'); history = r.get('automaticEvents')
        require(type(budget) is int and previous <= budget <= 1 and
                isinstance(history, list) and history == events[:len(history)] and len(history) <= budget)
        previous = budget
    require(previous == 1)
    selected = [r for r in rows if r['elapsed'] >= e['elapsedAfter']]
    fixed = 'dash-video-w320-h180-b350000' if scenario == 'fixed-during-preparation' else None
    cap = None if fixed else 320
    require(len(selected) >= 3)
    for r in selected:
        expected = dict(acceptedMaximumWidth=cap, acceptedMaximumHeight=None, acceptedMaximumBitrate=None,
                        fixedTrackId=fixed, maximumWidth=cap or 0, maximumHeight=100000 if cap else 0, peak=0)
        require(all(k in r and r[k] == v for k,v in expected.items()))
    require(all(isinstance(f, dict) and finite(f.get('elapsed')) and
                type(f.get('frames')) is int and f['frames'] >= 0 and
                type(f.get('width')) is int and 0 <= f['width'] <= 16384 for f in frames))
    require(all(a['elapsed'] < b['elapsed'] for a,b in zip(frames,frames[1:])))
    published = [f for f in frames if e['publicCommandCompletedElapsed'] <= f['elapsed'] <= rows[-1]['elapsed'] and f['frames'] > 0]
    require(len(published) >= 3 and all(f['width'] == 320 for f in published))
    return dict(scenario=scenario, oldCandidateRejected=True, sameSession=True,
                sourceAttempts=1, policyRows=len(selected), publishedFrames=sum(f['frames'] for f in published),
                capabilityAccepted=False, continuityAccepted=False, physicalOutputVerified=False)


'''
assert at in s;s=s.replace(at,t+at)
s=s.replace("cycle = public_policy_cycle(args)","cycle = public_policy_cycle(args)\n        race = public_policy_race(args)\n        receipt['publicPolicyRace'] = race")
s=s.replace("YL_ABR_PROBE_PUBLIC_POLICY_CYCLE='1' if cycle else '0',","YL_ABR_PROBE_PUBLIC_POLICY_CYCLE='1' if cycle else '0',\n            YL_ABR_PROBE_PUBLIC_POLICY_RACE='1' if race else '0',")
s=s.replace("        if cycle:\n            receipt['publicPolicyObservation']", "        if race:\n            receipt['publicRaceObservation'] = summarize_public_race(rows,\n                read_rows(out/'frame-samples.jsonl'), receipt.get('policyObservation'))\n        elif any(row.get('publicPolicyRace') is True for row in rows):\n            raise ValueError('unexpected public host preparation race')\n        if cycle:\n            receipt['publicPolicyObservation']")
s=s.replace("    p.add_argument('--public-policy-cycle', action='store_true',", "    p.add_argument('--public-policy-race', action='store_true',\n                   help='typed public caps/fixed command after candidate readiness; requires cancellation')\n    p.add_argument('--public-policy-cycle', action='store_true',")
p.write_text(s)
