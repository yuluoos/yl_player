"""Owned Apple ABR access-log observation; does not certify adaptive policy."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import threading
import time
import uuid
from xml.parsers.expat import ExpatError
from network_profile import load_profiles, make_server, owned_bind_host
from prepare_fixture import create
import abr_device


def policy_trace_version(rows):
    if not any(isinstance(row, dict) and 'policySamplingVersion' in row for row in rows):
        return None
    if not all(isinstance(row, dict) and type(row.get('policySamplingVersion')) is int and
               row['policySamplingVersion'] == 1 for row in rows):
        raise ValueError('inconsistent or unsupported policy sampling version')
    return 1


def summarize_policy(rows, *, expected_attempts):
    """Validate exact native decisions; an untriggered run is not path coverage."""
    reasons = {'invalidSample', 'playbackIneligible', 'insufficientBuffer', 'nearEnd',
        'nonMonotonic', 'highOutput', 'highNotObserved', 'notLowOutput', 'noOverdue',
        'backoff', 'ticketReady', 'inFlight', 'budgetExhausted', 'windowStarted',
        'countersReset', 'windowPending', 'noProgress', 'insufficientRequests',
        'insufficientBandwidth', 'firstQualifiedWindow', 'reserved'}
    def require(value):
        if not value: raise ValueError('invalid recovery policy evidence')
    def finite(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    require(type(expected_attempts) is int and 0 <= expected_attempts <= 2)
    require(isinstance(rows, list) and 1 <= len(rows) <= 1000)
    counts = {}; previous = -1; attempts = 0; reservations = 0; tickets = 0; pending = None
    rates = []; anchor = None; qualified = 0
    for row in rows:
        require(isinstance(row, dict) and isinstance(row.get('reason'), str) and row['reason'] in reasons)
        reason = row['reason']; elapsed = row.get('elapsed')
        require(finite(elapsed) and elapsed > previous); previous = elapsed
        for key in ('generation', 'width', 'overdue', 'qualifiedWindows'):
            require(type(row.get(key)) is int and row[key] >= 0)
        for key in ('bytes', 'requests'): require(type(row.get(key)) is int)
        require(row['qualifiedWindows'] <= 1)
        for key in ('allowed', 'sawHigh'): require(type(row.get(key)) is bool)
        for key in ('position', 'remaining', 'bufferAhead', 'transfer'):
            require(row.get(key) is None or (type(row.get(key)) in (int, float) and math.isfinite(row[key])))
        # Rejected samples may contain negative/unknown native inputs. Preserve
        # them only under the same guard priority as observe(); never qualify them.
        eligible = (row['allowed'] and all(finite(row[key]) for key in ('position', 'transfer')) and
                    row['bytes'] >= 0 and row['requests'] >= 0 and
                    row['bufferAhead'] is not None and row['bufferAhead'] >= 5 and
                    row['remaining'] is not None and row['remaining'] >= 20)
        rejection = None
        if not row['allowed']: rejection = 'playbackIneligible'
        elif row['bufferAhead'] is not None and row['bufferAhead'] < 5: rejection = 'insufficientBuffer'
        elif row['remaining'] is not None and row['remaining'] < 20: rejection = 'nearEnd'
        elif not eligible: rejection = 'invalidSample'
        if rejection is not None:
            require(reason == rejection)
        else:
            require(reason not in ('playbackIneligible', 'insufficientBuffer', 'nearEnd', 'invalidSample'))
            if reason == 'highOutput': require(row['width'] == 640 and row['sawHigh'])
            elif reason == 'highNotObserved': require(row['width'] != 640 and not row['sawHigh'])
            elif reason == 'notLowOutput': require(row['sawHigh'] and row['width'] not in (320, 640))
            elif reason == 'noOverdue': require(row['sawHigh'] and row['width'] == 320 and row['overdue'] == 0)
            elif reason != 'nonMonotonic':
                require(row['sawHigh'] and row['width'] == 320 and row['overdue'] > 0)
        budget = row.get('attempts')
        require(type(budget) is int and attempts <= budget <= 2)
        bitrate = row.get('windowBitrate'); requests = row.get('windowRequests'); due = row.get('pendingDue')
        require(bitrate is None or finite(bitrate))
        require(requests is None or (type(requests) is int and requests >= 0))
        require(due is None or finite(due))
        if bitrate is not None: rates.append(bitrate)
        completed_window = reason in ('noProgress', 'insufficientRequests',
            'insufficientBandwidth', 'firstQualifiedWindow', 'reserved')
        if completed_window:
            require(anchor is not None and row['generation'] == anchor['generation'] and
                    elapsed-anchor['elapsed'] >= 8)
            require(all(row[key] >= anchor[key] for key in ('bytes', 'transfer', 'requests')))
            duration = row['transfer']-anchor['transfer']
            measured = (row['bytes']-anchor['bytes'])*8/duration if duration > 0 else 0
            require(bitrate is not None and math.isclose(bitrate, measured, rel_tol=1e-9, abs_tol=1e-6))
            require(requests == row['requests']-anchor['requests'])
            if reason in ('firstQualifiedWindow', 'reserved'):
                require(row['position'] > anchor['position'])
                require(qualified == (0 if reason == 'firstQualifiedWindow' else 1))
                qualified = 1 if reason == 'firstQualifiedWindow' else 0
            else:
                qualified = 0
            anchor = None if reason == 'reserved' else row
        elif reason in ('windowStarted', 'countersReset'):
            anchor = row; qualified = 0
        elif reason == 'windowPending':
            require(anchor is not None and row['generation'] == anchor['generation'] and
                    elapsed-anchor['elapsed'] < 8)
        else:
            anchor = None; qualified = 0
        require(row['qualifiedWindows'] == qualified)
        if reason in ('reserved', 'firstQualifiedWindow'):
            require(bitrate is not None and bitrate >= 955000 and requests is not None and requests >= 3)
            require(row['allowed'] and row['sawHigh'] and row['width'] == 320 and
                    row['bufferAhead'] >= 5 and row['remaining'] >= 20 and row['overdue'] > 0)
        if reason == 'reserved':
            require(budget == attempts + 1 and due is not None and
                    math.isclose(due-elapsed, .5 if budget == 1 else 1, abs_tol=1e-6))
            pending = (budget, row['generation'], due); reservations += 1
        else:
            require(budget == attempts)
            if reason == 'ticketReady':
                require(pending is not None and pending[0] == budget and
                        pending[1] == row['generation'] and elapsed >= pending[2])
                pending = None; tickets += 1
            elif reason != 'backoff': pending = None
        attempts = budget
        counts[reason] = counts.get(reason, 0) + 1
    require(attempts == expected_attempts)
    return dict(samples=len(rows), reasonCounts=counts, attempts=attempts,
        reservations=reservations, tickets=tickets, triggerExercised=tickets > 0,
        windowBitrateMinimum=min(rates) if rates else None,
        windowBitrateMaximum=max(rates) if rates else None, capabilityAccepted=False)


def summarize(rows, *, expected_duration_seconds=None, expected_transport=None, expected_startup_delay_ms=0,
              expected_recovery_action=None, expected_auto_scenario='normal'):
    def require(value):
        if not value: raise ValueError('incomplete or invalid ABR observation')
    require(isinstance(rows,list) and 2<=len(rows)<=1000)
    require(all(isinstance(row, dict) for row in rows))
    intervention = None
    if expected_recovery_action is None:
        require(all(row.get('recoveryAction') in (None, 'none') and
                    row.get('recoveryAttempt') is None for row in rows))
    if expected_recovery_action is not None:
        require(expected_recovery_action in ('none', 'seek-current', 'reload-source', 'auto-reload'))
        require(all(row.get('recoveryAction') == expected_recovery_action for row in rows))
        require(expected_auto_scenario in ('normal', 'pause-first', 'pause-during-preparation'))
        require(all(row.get('autoScenario') == expected_auto_scenario for row in rows))
        require(all(type(row.get('frameSamplingVersion')) is int and row['frameSamplingVersion'] == 2 for row in rows))
        attempts = [row.get('recoveryAttempt') for row in rows if row.get('recoveryAttempt') is not None]
        if expected_recovery_action == 'auto-reload':
            require(not attempts)
            previous = 0
            final = rows[-1].get('automaticEvents')
            require(isinstance(final, list) and len(final) <= 2)
            for row in rows:
                budget = row.get('automaticAttempts')
                require(type(budget) is int and previous <= budget <= 2)
                previous = budget
                events = row.get('automaticEvents')
                require(isinstance(events, list) and events == final[:len(events)] and len(events) <= budget)
            previous_attempt = 0
            for event in final:
                require(isinstance(event, dict) and type(event.get('attempt')) is int and
                        previous_attempt < event['attempt'] <= previous)
                previous_attempt = event['attempt']
                require(event.get('outcome') in ('installed', 'cancelled', 'preparationFailed'))
                for key in ('elapsed', 'elapsedAfter', 'due', 'positionBefore'):
                    require(type(event.get(key)) in (int, float) and math.isfinite(event[key]) and event[key] >= 0)
                require(event['due'] <= event['elapsed'] <= event['elapsedAfter'] <= rows[-1]['elapsed'])
                if event['outcome'] == 'installed':
                    require(event.get('itemChanged') is True)
                    if intervention is None: intervention = event
        elif expected_recovery_action == 'none':
            require(not attempts)
        else:
            require(bool(attempts) and all(attempt == attempts[0] for attempt in attempts))
            attempt = attempts[0]
            require(isinstance(attempt, dict) and attempt.get('action') == expected_recovery_action)
            require(rows[-1].get('recoveryAttempt') == attempt)
            require(attempt.get('completed') is True)
            require(attempt.get('itemChanged') is (expected_recovery_action == 'reload-source'))
            for key in ('elapsed', 'positionBefore'):
                require(type(attempt.get(key)) in (int, float) and math.isfinite(attempt[key]) and attempt[key] >= 0)
            require(rows[0]['elapsed'] <= attempt['elapsed'] <= rows[-1]['elapsed'])
            if 'elapsedAfter' in attempt:
                require(type(attempt['elapsedAfter']) in (int, float) and math.isfinite(attempt['elapsedAfter']) and
                        attempt['elapsed'] <= attempt['elapsedAfter'] <= rows[-1]['elapsed'])
            intervention = attempt
    if expected_duration_seconds is not None or expected_transport is not None:
        require(type(expected_duration_seconds) is int and expected_duration_seconds in (40, 120))
        require(expected_transport in ('managed-dash', 'direct-hls-control'))
        require(type(expected_startup_delay_ms) is int and 0 <= expected_startup_delay_ms <= 2000)
        require(all(type(row.get('programmeDurationSeconds')) is int and
                    row.get('programmeDurationSeconds') == expected_duration_seconds and
                    type(row.get('startupDelayMs')) is int and row['startupDelayMs'] == expected_startup_delay_ms and
                    row.get('transport') == expected_transport for row in rows))
        position = rows[-1].get('position')
        require(type(position) in (int, float) and math.isfinite(position) and
                position >= expected_duration_seconds - .5)
    widths=[];previous=-1
    for row in rows:
        elapsed=row['elapsed']
        require(type(elapsed) in (int,float) and math.isfinite(elapsed) and elapsed>previous)
        previous=elapsed
        require(row['peak']==0 and row['status'] in (0,1))
        width=row['width'];require(type(width) in (int,float) and math.isfinite(width) and 0<=width<=16384)
        if width and (not widths or width!=widths[-1]):widths.append(width)
    require(rows[-1]['completed'] is True and type(rows[-1]['framesPublished']) is int and rows[-1]['framesPublished']>0)
    last=(rows[-1].get('logs') or [{}])[-1]
    observed=last.get('observedBitrate')
    require(observed is None or (type(observed) in (int,float) and math.isfinite(observed)))
    recovered=False;down=False
    for a,b in zip(widths,widths[1:]):
        if b<a:down=True
        elif down and b>a:recovered=True
    return dict(schemaVersion=1,geometryWidths=widths,downshiftObserved=down,
        recoveryInterventionApplied=intervention is not None,
        highOutputAfterInterventionObserved=(any(row['elapsed'] > intervention.get('elapsedAfter', intervention['elapsed']) and
            row['width'] == 640 for row in rows) if intervention else None),
        upshiftAfterDownshiftObserved=recovered,lastObservedBitrate=observed,
        lastIndicatedBitrate=last.get('indicatedBitrate'),framesPublished=rows[-1]['framesPublished'],
        diagnosticOnly=True,internalABRDecisionVerified=False,capabilityAccepted=False,
        physicalOutputVerified=False)


def summarize_frames(rows, *, expected_frames):
    def require(value):
        if not value: raise ValueError('invalid frame publication observation')
    require(type(expected_frames) is int and expected_frames > 0 and 2 <= len(rows) <= 15000)
    previous_time = -1; generation = 0; total = 0; published = []; pump_gaps = []
    has_clears = any('textureClears' in row for row in rows if isinstance(row, dict))
    previous_clears = 0; generations = set()
    for row in rows:
        require(isinstance(row, dict))
        elapsed = row.get('elapsed'); position = row.get('position')
        require(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed > previous_time)
        require(type(position) in (int, float) and math.isfinite(position) and position >= 0)
        require(type(row.get('generation')) is int and generation <= row['generation'])
        generation = row['generation']
        generations.add(generation)
        if has_clears:
            require(type(row.get('textureClears')) is int and row['textureClears'] >= previous_clears)
            previous_clears = row['textureClears']
        count = row.get('frames'); require(type(count) is int and 0 <= count <= 2)
        require(type(row.get('width')) is int and (row['width'] in (320, 640) if count else row['width'] == 0))
        if previous_time >= 0: pump_gaps.append((elapsed - previous_time) * 1000)
        previous_time = elapsed; total += count
        if count: published.append(row)
    require(total == expected_frames)
    boundaries = [dict(generationBefore=a['generation'], generationAfter=b['generation'],
        elapsedBefore=a['elapsed'], elapsedAfter=b['elapsed'],
        publicationGapMs=(b['elapsed']-a['elapsed'])*1000,
        positionDeltaMs=(b['position']-a['position'])*1000,
        textureClears=b['textureClears']-a['textureClears'] if has_clears else None)
        for a,b in zip(published,published[1:]) if a['generation'] != b['generation']]
    return dict(frameSamplingVersion=2, sampleCount=len(rows), publishedFrames=total,
        maximumPumpGapMs=max(pump_gaps),
        maximumPublishedFrameGapMs=max(((b['elapsed']-a['elapsed'])*1000 for a,b in zip(published,published[1:])), default=None),
        lastPublicationSampleElapsed=published[-1]['elapsed'],
        observationEndElapsed=rows[-1]['elapsed'],
        trailingNoPublicationMs=(rows[-1]['elapsed']-published[-1]['elapsed'])*1000,
        replacementBoundaries=boundaries,
        generationsWithoutPublishedFrame=sorted(generations - {row['generation'] for row in published}),
        continuityAccepted=False, audioSynchronizationVerified=False, physicalOutputVerified=False)


def read_rows(path):
    if path.stat().st_size>16*1024*1024:raise ValueError('observation exceeds 16 MiB')
    return [json.loads(line) for line in path.read_text().splitlines()]


def process_identity(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=', '-o', 'comm='],
                            capture_output=True, text=True, timeout=5)
    if result.returncode not in (0, 1):
        raise RuntimeError('cannot inspect owned process')
    return result.stdout.strip()


def cleanup_owned(owned):
    if owned is None:
        return False
    pid, identity = owned
    current = process_identity(pid)
    if not current:
        return True
    if current != identity:
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    for _ in range(40):
        current = process_identity(pid)
        if not current:
            return True
        if current != identity:
            return False
        time.sleep(.1)
    return False


def observe_owned(out, token, executable):
    proof = out / 'process.json'
    if not proof.exists():
        return None
    if proof.stat().st_size > 4096:
        raise ValueError('invalid process proof')
    value = json.loads(proof.read_text())
    pid = value['pid']
    path = value['executable']
    if (value['token'] != token or type(pid) is not int or pid <= 1 or
        not isinstance(path, str) or Path(path).name != executable or '.app/' not in path):
        raise ValueError('invalid process proof')
    identity = process_identity(pid)
    if identity:
        # macOS reports the canonical /private/tmp path in ps while the native
        # host may launch through /tmp. Preserve the full start-time identity
        # for cleanup, but compare the executable's resolved path here.
        fields = identity.split(maxsplit=5)
        if (len(fields) != 6 or
                Path(fields[5]).resolve(strict=True) != Path(path).resolve(strict=True)):
            raise ValueError('process proof executable mismatch')
    return (pid, identity) if identity else None


def wait_for_native(process, command, observe, timeout=240):
    deadline = time.monotonic() + timeout
    while (code := process.poll()) is None:
        observe()
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(command, timeout)
        time.sleep(.25)
    # A child can exit during sleep, or the parent can resume after its deadline.
    # Observing exit 0 at that point is not evidence of timely completion.
    if time.monotonic() >= deadline:
        raise subprocess.TimeoutExpired(command, timeout)
    return code


def candidate_preparation(args):
    mode = getattr(args, 'candidate_preparation', 'manifest-only')
    if mode not in ('manifest-only', 'asset-metadata', 'asset-preroll'):
        raise ValueError('invalid candidate preparation')
    if mode != 'manifest-only' and (getattr(args, 'recovery_action', 'none') != 'auto-reload' or
            getattr(args, 'duration_seconds', 40) != 120 or getattr(args, 'direct_hls_control', False)):
        raise ValueError('candidate preparation requires managed 120s automatic diagnostic')
    if getattr(args, 'auto_scenario', 'normal') == 'pause-during-preparation' and mode != 'asset-preroll':
        raise ValueError('mid-preparation pause requires preroll')
    return mode


def validate_candidate_preparation(rows, expected):
    if expected not in ('manifest-only', 'asset-metadata', 'asset-preroll') or not rows or not all(
            isinstance(row, dict) and row.get('candidatePreparation', 'manifest-only') == expected
            for row in rows):
        raise ValueError('native candidate preparation does not match request')
    if expected == 'asset-preroll':
        for row in rows:
            events = row.get('automaticEvents', [])
            if not isinstance(events, list):
                raise ValueError('invalid preroll event evidence')
            for event in events:
                if not isinstance(event, dict):
                    raise ValueError('invalid preroll event evidence')
                if event.get('outcome') == 'installed' and not (
                        event.get('warmupOutcome') == 'ready' and event.get('warmupStage') == 'ready' and
                        event.get('warmupDetached') is True and event.get('warmupReusesPrerolledItem') is False and
                        event.get('freshPreparedItemInstalled') is True and event.get('warmupOldItemRetained') is True):
                    raise ValueError('preroll installation lacks fresh item preparation evidence')


def run(args):
    out=args.directory.resolve();out.mkdir(parents=True,exist_ok=False)
    receipt=dict(diagnosticOnly=True,capabilityAccepted=False,errors=[],exitCode=None)
    server=None;thread=None;process=None;log=None;output=None;owned=None
    token=uuid.uuid4().hex
    before=None;products=None
    physical_device = getattr(args, 'physical_device', None)
    bundle = None; executable = None
    receipt['deviceKind'] = 'physical' if physical_device else ('simulator' if args.device else 'macos')
    def hashes():
        paths=[p for p in products.rglob('*') if p.is_file() and ('.app/' in str(p) or p.suffix=='.xctestrun')]
        return {str(p.relative_to(products)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    try:
        host = getattr(args, 'owned_host', None)
        if physical_device:
            if args.device or not re.fullmatch('[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}', physical_device) or host is None:
                raise ValueError('invalid physical device selection')
            host = owned_bind_host(host)
        elif host is not None:
            raise ValueError('private listener requires physical device selection')
        else: host = '127.0.0.1'
        duration_seconds = getattr(args, 'duration_seconds', 40)
        direct = getattr(args, 'direct_hls_control', False)
        startup_delay_ms = getattr(args, 'startup_delay_ms', 0)
        recovery_action = getattr(args, 'recovery_action', 'none')
        auto_scenario = getattr(args, 'auto_scenario', 'normal')
        if auto_scenario not in ('normal', 'pause-first', 'pause-during-preparation') or (auto_scenario != 'normal' and recovery_action != 'auto-reload'):
            raise ValueError('invalid automatic recovery scenario')
        receipt['autoScenario'] = auto_scenario
        preparation_mode = candidate_preparation(args)
        receipt['candidatePreparation'] = preparation_mode
        if recovery_action not in ('none', 'seek-current', 'reload-source', 'auto-reload') or (direct and recovery_action != 'none'):
            raise ValueError('invalid managed recovery diagnostic')
        if recovery_action != 'none' and duration_seconds != 120:
            raise ValueError('recovery diagnostic requires 120 seconds')
        receipt['recoveryAction'] = recovery_action
        if type(startup_delay_ms) is not int or not 0 <= startup_delay_ms <= 2000:
            raise ValueError('invalid diagnostic startup delay')
        receipt['transport'] = 'direct-hls-control' if direct else 'managed-dash'
        receipt['startupDelayMs'] = startup_delay_ms
        products=args.products.resolve(strict=True)
        manifests=list(products.glob('*.xctestrun'))
        if len(manifests)!=1:raise ValueError('expected one built test manifest')
        def absolute(value):
            if isinstance(value,str):return value.replace('__TESTROOT__',str(products))
            if isinstance(value,list):return [absolute(x) for x in value]
            if isinstance(value,dict):return {k:absolute(v) for k,v in value.items()}
            return value
        config=absolute(plistlib.loads(manifests[0].read_bytes()))
        target=config['RunnerTests']
        app=Path(target['TestHostPath'])
        if app.suffix!='.app':
            app=app.parent
            if app.name=='MacOS':app=app.parent.parent
        info=app/('Contents/Info.plist' if (app/'Contents').is_dir() else 'Info.plist')
        executable=plistlib.loads(info.read_bytes())['CFBundleExecutable']
        if physical_device: bundle=plistlib.loads(info.read_bytes())['CFBundleIdentifier']
        before=hashes();receipt['binaryHashes']=before
        receipt['fixture']=create(out/'fixture', duration_seconds=duration_seconds,
                                  direct_hls_control=direct)
        profile=load_profiles(args.profiles)[args.profile];receipt['profileSha256']=profile.sha256
        destination='platform=macOS,arch=arm64'
        if args.device:
            if not re.fullmatch('[0-9A-Fa-f-]{36}',args.device):raise ValueError('invalid simulator identifier')
            destination='platform=iOS Simulator,id='+args.device
        if physical_device: destination='platform=iOS,id='+physical_device
        log=(out/'requests.jsonl').open('w');output=(out/'xcode.log').open('w')
        server=make_server(out/'fixture',profile,log,0,start_on_first_get=True,run_id='abr-accesslog',
                           owned_host=host if physical_device else None)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        target.setdefault('EnvironmentVariables',{}).update(
            YL_ABR_PROBE_TOKEN=token,YL_ABR_PROBE_URL=f'http://{host}:{server.server_port}/manifest.mpd',YL_ABR_PROBE_DIRECTORY=str(out),
            YL_ABR_PROBE_DEVICE='1' if physical_device else '0', YL_ABR_PROBE_OWNED_HOST=host if physical_device else '',
            YL_ABR_PROBE_SECONDS=str(duration_seconds), YL_ABR_PROBE_DIRECT_HLS='1' if direct else '0',
            YL_ABR_PROBE_RECOVERY_ACTION=recovery_action,
            YL_ABR_PROBE_AUTO_SCENARIO=auto_scenario,
            YL_ABR_PROBE_CANDIDATE_PREPARATION=preparation_mode,
            YL_ABR_PROBE_STARTUP_DELAY_MS=str(startup_delay_ms), YL_ABR_PROBE_PROFILE_SHA256=profile.sha256)
        manifest=out/'probe.xctestrun';manifest.write_bytes(plistlib.dumps(config))
        command=['xcodebuild','test-without-building','-quiet','-xctestrun',str(manifest),
            '-destination',destination,'-only-testing:RunnerTests/YlDashResourceLoaderTests/testActualOwnedDashAdaptiveObservation',
            '-parallel-testing-enabled','NO','-resultBundlePath',str(out)+'.xcresult']
        process=subprocess.Popen(command,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            def observe():
                nonlocal owned
                if not physical_device and owned is None:owned=observe_owned(out,token,executable)
            receipt['exitCode']=wait_for_native(process, command, observe)
        except subprocess.TimeoutExpired:
            receipt['errors'].append('native deadline')
            if process.poll() is None:
                os.killpg(process.pid,signal.SIGTERM)
                try:process.wait(timeout=10)
                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=10)
        if physical_device: abr_device.collect(physical_device, bundle, out, token)
        rows=read_rows(out/'rows.jsonl')
        if not rows or not isinstance(rows[-1], dict):
            raise ValueError('missing final ABR observation')
        if physical_device and not all(isinstance(row, dict) and row.get('captureDeviceKind') == 'physical' for row in rows):
            raise ValueError('physical capture requires native device identity')
        policy_version = policy_trace_version(rows)
        if recovery_action == 'auto-reload' and policy_version == 1:
            receipt['policyObservation'] = summarize_policy(read_rows(out/'policy-decisions.jsonl'),
                expected_attempts=rows[-1]['automaticAttempts'])
        # Keep valid publication evidence even when playback never reaches EOF.
        receipt['continuityObservation'] = summarize_frames(read_rows(out/'frame-samples.jsonl'),
            expected_frames=rows[-1]['framesPublished'])
        validate_candidate_preparation(rows, preparation_mode)
        receipt['observation']=summarize(rows, expected_duration_seconds=duration_seconds,
                                         expected_transport=receipt['transport'], expected_startup_delay_ms=startup_delay_ms,
                                         expected_recovery_action=recovery_action, expected_auto_scenario=auto_scenario)
    except (OSError,ValueError,KeyError,TypeError,plistlib.InvalidFileException,ExpatError,
            subprocess.SubprocessError) as error:
        receipt['errors'].append(type(error).__name__)
    finally:
        if process is not None and process.poll() is None:
            try: os.killpg(process.pid,signal.SIGTERM)
            except ProcessLookupError: pass
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError: pass
                process.wait(timeout=10)
        try:
            receipt['ownedProcessExited']=(abr_device.cleanup(physical_device,out,token,executable)
                if physical_device and executable else cleanup_owned(owned))
        except (OSError,ValueError,KeyError,TypeError,RuntimeError,subprocess.SubprocessError):
            receipt['ownedProcessExited']=False
        if process is not None and not receipt['ownedProcessExited']:
            receipt['errors'].append('owned process cleanup unverified')
        if server:server.shutdown();server.server_close()
        if thread:thread.join(timeout=5)
        if log:log.close()
        if output:output.close()
        receipt['binaryIdentityUnchanged']=False
        if before is not None:
            try:
                receipt['binaryIdentityUnchanged']=before==hashes()
            except OSError:
                receipt['errors'].append('binary identity recheck failed')
        receipt['passed']=(receipt['exitCode']==0 and not receipt['errors'] and receipt['binaryIdentityUnchanged']
                           and isinstance(receipt.get('observation'), dict)
                           and isinstance(receipt.get('continuityObservation'), dict))
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    return receipt


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--products',type=Path,required=True);p.add_argument('--directory',type=Path,required=True)
    p.add_argument('--device',help='Explicit iOS Simulator UUID; omit for native arm64 macOS')
    p.add_argument('--physical-device', help='Explicit paired iPhone UDID; requires --owned-host')
    p.add_argument('--owned-host', help='Explicit owned RFC1918 IPv4 interface for physical-device capture')
    p.add_argument('--profiles',type=Path,default=Path(__file__).with_name('profiles.json'))
    p.add_argument('--duration-seconds',type=int,choices=(40,120),default=40)
    p.add_argument('--startup-delay-ms',type=int,default=0,
                   help='0..2000ms diagnostic delay after arming/preparing; never changes the frozen profile')
    p.add_argument('--recovery-action', choices=('none', 'seek-current', 'reload-source', 'auto-reload'), default='none',
                   help='one managed 120s diagnostic intervention; never natural ABR acceptance')
    p.add_argument('--auto-scenario', choices=('normal', 'pause-first', 'pause-during-preparation'), default='normal')
    p.add_argument('--candidate-preparation', choices=('manifest-only', 'asset-metadata', 'asset-preroll'), default='manifest-only',
                   help='owned diagnostic only; requires native mode echo and unchanged ticket revalidation')
    p.add_argument('--direct-hls-control',action='store_true',
                   help='system-only direct HLS control; not a production DASH acceptance run')
    p.add_argument('--profile',default='down-and-recover-v1');a=p.parse_args()
    result=run(a);print(json.dumps({k:v for k,v in result.items() if k!='binaryHashes'},indent=2))
    return 0 if result['passed'] else 1

if __name__=='__main__':raise SystemExit(main())
