from pathlib import Path
import sys
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text().replace("row['policySamplingVersion'] == 1 for row in rows):","row['policySamplingVersion'] in (1,2) and row['policySamplingVersion'] == rows[0]['policySamplingVersion'] for row in rows):",1).replace('    return 1\n\n\ndef summarize_policy','    return rows[0][\'policySamplingVersion\']\n\n\ndef summarize_policy',1)
marker='\ndef summarize(rows, *, expected_duration_seconds=None'
fn='''
def validate_recovery_authority(rows, policy):
    """V2 binds every observed candidate to its transport/credential authority."""
    if policy_trace_version(rows) != 2: return
    def require(value):
        if not value: raise ValueError('invalid recovery credential authority')
    require(isinstance(policy,dict))
    require(isinstance(policy.get('intentSamples'),list) and bool(policy['intentSamples']))
    require(isinstance(policy.get('credentialSamples'),list) and bool(policy['credentialSamples']))
    events=rows[-1].get('automaticEvents');authorities=policy.get('ticketAuthorities')
    require(isinstance(events,list) and isinstance(authorities,list) and len(events)==len(authorities))
    for e,a in zip(events,authorities):
        require(isinstance(e,dict) and isinstance(a,dict) and type(e.get('attempt')) is int and e['attempt']==a.get('attempt'))
        require(all(type(x) in (int,float) and math.isfinite(x) for x in (e.get('elapsed'),a.get('elapsed'))))
        require(0<=e['elapsed']-a['elapsed']<=.05)
        for event_key,key in [('ticketIntentRevision','intentRevision'),('ticketCredentialRevision','credentialRevision')]:
            require(type(e.get(event_key)) is int and type(a.get(key)) is int and 0<=e[event_key]<2**64 and e[event_key]==a[key])

'''
assert marker in s;s=s.replace(marker,'\n'+fn+marker,1).replace("recovery_action == 'auto-reload' and policy_version == 1:","recovery_action == 'auto-reload' and policy_version in (1,2):",1).replace("                expected_attempts=rows[-1]['automaticAttempts'])","                expected_attempts=rows[-1]['automaticAttempts'])\n            validate_recovery_authority(rows,receipt['policyObservation'])",1);p.write_text(s)
p=Path('tool/playback_network/test_abr_policy.py');s=p.read_text().replace("        for rows in [[{'policySamplingVersion': 2}]", "        self.assertEqual(fn([{'policySamplingVersion': 2}] * 2), 2)\n        for rows in [[{'policySamplingVersion': 3}], [{'policySamplingVersion': 1}, {'policySamplingVersion': 2}]");p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();assert '"policySamplingVersion": 1' in s;s=s.replace('"policySamplingVersion": 1','"policySamplingVersion": 2');p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
p=Path('tool/playback_network/README.md');s=p.read_text();s+='''

### Recovery credential provenance

Policy sampling version 2 adds `credentialRevision` alongside transport intent.
It is the count of distinct resources permanently stripped within the same user
Load; repeated stripping is idempotent. It contains no URLs or credential values.
Recovery preparation shares the active HLS loader's credential context and request
metadata. A change resets qualification windows and revokes pending/in-flight
authority without refunding the source attempt budget. Every candidate event binds
both ticket revisions to its issuing decision. V2 rejects missing or mismatched
authority; historical V1 remains separately identifiable, without upgrading its
coverage. No production automatic recovery is enabled by this diagnostic policy.

Local contracts combine actual AVPlayer candidate readiness with an owned
cross-origin redirect/return request, and verify candidate cancellation, resource
release and credential stripping through a separately prepared shared-context
proxy. Synthetic bandwidth samples issue the test ticket. This is not a full
public/Dart credential race, physical playback continuity or high-tier recovery
acceptance; those remain separate pending checks.
''';p.write_text(s)
