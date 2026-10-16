"""Gate a frozen native-consumer scope using same-player raw A/V observations.

A scoped pass is never full P03 or release/physical-device acceptance. The runner
must additionally verify pre/post artifact bytes and the actual native test exit.
"""
import base64
import functools
import hashlib
import math
import re
import struct

HASH = re.compile(r'[0-9a-f]{64}\Z')
RGB = ((255,0,0),(0,255,0),(0,0,255),(255,255,255))
YUV = ((81,90,240),(145,54,34),(41,240,110),(235,128,128))


def require(value, reason):
    if not value: raise ValueError(reason)


@functools.lru_cache(maxsize=64)
def basis(hz, count, rate):
    return tuple((math.cos(2*math.pi*hz*i/rate), math.sin(2*math.pi*hz*i/rate)) for i in range(count))


def amplitude(samples, hz, rate):
    """Projection of retained actual PCM; no offset search or waveform fitting."""
    pairs=basis(hz,len(samples),rate)
    return 2*math.hypot(sum(v*p[0] for v,p in zip(samples,pairs)),sum(v*p[1] for v,p in zip(samples,pairs)))/len(samples)


def origin(record, row):
    require(all(record.get(k)==row.get(k) for k in ('runId','sessionId','buildSha256')), 'spliced_origin')


def pcm_window(window, row, case, phase, marker):
    origin(window,row)
    require(window.get('phase')==phase and window.get('marker')==marker,'pcm_phase')
    channels=case['channels']
    require(window.get('rate')==48000 and type(window.get('rate')) is int and
            window.get('channels')==channels and window.get('frames')==8192,'pcm_format')
    start=marker*1_000_000+250_000 if phase=='play' else int(phase.split('-')[1])*1000+100_000
    require(type(window.get('startUs')) is int and start<=window['startUs']<=start+2000,'pcm_time')
    encoded=window.get('pcmF32LE')
    require(isinstance(encoded,str) and len(encoded)<=262144,'pcm_payload')
    raw=base64.b64decode(encoded,validate=True)
    require(len(raw)==8192*channels*4 and hashlib.sha256(raw).hexdigest()==window.get('pcmSha256'),'pcm_hash')
    values=struct.unpack('<'+str(8192*channels)+'f',raw)
    require(all(math.isfinite(v) and abs(v)<=1 for v in values),'pcm_nonfinite_or_clipped')
    base=440+marker*220
    measured=[]
    for channel in range(channels):
        samples=values[channel::channels]
        hz=60+marker*10 if channels==6 and channel==3 else base+channel*55
        own=amplitude(samples,hz,48000)
        require(own>0.008,'pcm_marker')
        # Stereo native output must preserve left/right identity even for Lo/Ro.
        if channels==2:
            require(amplitude(samples,base+(1-channel)*55,48000)<own*0.1,'pcm_channel_swap')
            if case['caseId']=='mkv-avc-ac3-51':
                for mixed in (base+110,base+(4+channel)*55):
                    require(abs(amplitude(samples,mixed,48000)/own-math.sqrt(.5))<.08,'pcm_downmix')
                require(amplitude(samples,60+marker*10,48000)<own*.1,'pcm_lfe_leak')
        measured.append(dict(channel=channel,frequencyHz=hz,amplitude=own))
    return dict(phase=phase,marker=marker,channels=measured)


def validate(plan, rows):
    """Reject borrowed identities, missing required rows and scalar-only PCM claims.

    Values describe real decoder/output boundaries in the declared consumer.
    Product/test hashes identify their containers, which may be the same public
    Flutter debug APK. Public records also require Flutter view/session evidence.
    No result upgrades that scope to the complete format matrix, a release
    Flutter app, or physical A/V timing.
    """
    errors=[];supported=0;measurements=[]
    planned=plan.get('planned',[]) if isinstance(plan,dict) else []
    if not isinstance(planned,list):planned=[]
    result=dict(scopeAcceptance=False,fullAcceptance=False,requiredRows=len(planned),supportedRows=0,errors=errors,measurements=measurements)
    try:
        require(isinstance(plan,dict),'invalid_plan')
        require(plan.get('schema')==1 and plan.get('platform') in ('macos','ios','android'),'invalid_plan')
        require(isinstance(plan.get('runId'),str) and bool(plan['runId']),'invalid_run')
        for key in ('buildSha256','testSha256'):
            require(isinstance(plan.get(key),str) and HASH.fullmatch(plan[key]),'invalid_build')
        require(planned and all(isinstance(c,dict) and isinstance(c.get('caseId'),str) and
            isinstance(c.get('mediaHash'),str) and HASH.fullmatch(c['mediaHash']) and
            type(c.get('channels')) is int and c['channels'] in (2,6) for c in planned),'invalid_scope')
        require(len({c['caseId'] for c in planned})==len(planned),'invalid_scope')
        require(plan.get('phases')==[dict(phase='play',markers=[0,1,2,3]),dict(phase='seek-1250',markers=[1]),dict(phase='seek-2250',markers=[2]),dict(phase='seek-0',markers=[0])],'invalid_phases')
        require(isinstance(rows,list),'invalid_rows')
    except (ValueError,KeyError,TypeError) as error:
        errors.append(str(error));return result
    cases={c['caseId']:c for c in planned};seen=set();sessions=set()
    for row in rows:
        try:
            require(isinstance(row,dict),'invalid_row')
            case_id=row.get('caseId');require(case_id in cases and case_id not in seen,'duplicate_or_unplanned_row');seen.add(case_id)
            case=cases[case_id]
            require(all(row.get(k)==plan.get(k) for k in ('runId','buildSha256','testSha256','platform')),'identity_mismatch')
            require(row.get('mediaHash')==case['mediaHash'],'media_mismatch')
            if 'engine' in case:
                require(row.get('engine')==case['engine'],'engine_mismatch')
                if case['engine']=='media3':
                    require(row.get('decoderMode')=='HARDWARE' and all(isinstance(row.get(k),str) and row[k].strip() for k in ('decoderIdentity','audioDecoderIdentity')),'initialized_codec_unverified')
            session=row.get('sessionId');require(isinstance(session,str) and session and session not in sessions,'invalid_session');sessions.add(session)
            require(row.get('identityVerified') is True,'runtime_identity_unverified')
            require(row.get('schema')==1,'invalid_row_schema')
            if plan.get('artifactKind') in ('android-public-flutter-debug-apk','apple-public-flutter-debug-app'):
                apple=plan['artifactKind']=='apple-public-flutter-debug-app'
                require(plan['platform'] in ('ios','macos') if apple else plan['platform']=='android','public_platform_mismatch')
                pixel_source='flutter-native-view-display-layer' if apple else 'flutter-repaint-boundary'
                require(row.get('publicSessionId')==session and row.get('publicApi')=='YlPlayerController/YlPlayerView' and row.get('pixelSource')==pixel_source,'public_session_unverified')
                if apple:
                    require(row.get('nativeViewAttached') is True,'public_view_unverified')
                    require(row.get('audioClockMethod')=='renderer-paused-consumption','paused_readback_unverified')
                lifecycle=row.get('publicLifecycle',{})
                require(isinstance(lifecycle,dict) and all(lifecycle.get(k) is True for k in ('created','ready','firstFrame','completed','disposed')),'public_lifecycle_unverified')
            if plan['platform']=='android':require(row.get('audioClockMethod')=='audiotrack-playback-head','consumption_clock_unverified')
            require(row.get('audioOutputClosed') is True if plan['platform']=='android' else type(row.get('releasedAudioBytes')) is int and row['releasedAudioBytes']==0,'output_release_unverified')
            require(row.get('outcome')=='passed' and row.get('completed') is True and row.get('disposed') is True,'lifecycle_unverified')
            phases=row.get('phases',[]);require(isinstance(phases,list) and all(isinstance(p,dict) for p in phases),'invalid_phases');require([p.get('phase') for p in phases]==[p['phase'] for p in plan['phases']],'phase_coverage')
            local=[]
            for phase,expected in zip(phases,plan['phases']):
                origin(phase,row)
                pixels=phase.get('pixels',[])
                require(isinstance(pixels,list) and pixels and all(isinstance(p,dict) for p in pixels),'pixels_missing')
                times=[p.get('hostTimeUs') for p in pixels]
                require(all(type(t) is int and t>=0 for t in times) and times==sorted(times),'pixel_host_order')
                windows=phase.get('pcmWindows',[])
                require(isinstance(windows,list) and all(isinstance(w,dict) for w in windows),'pcm_coverage')
                require([w.get('marker') for w in windows]==expected['markers'],'pcm_coverage')
                for marker,window in zip(expected['markers'],windows):
                    matched=[]
                    for pixel in pixels:
                        value=pixel.get('value');clock=pixel.get('audioClockUs')
                        reference=RGB if pixel.get('format')=='rgb8' else YUV if pixel.get('format')=='yuv420-center' else None
                        if (reference and isinstance(value,list) and len(value)==3 and all(type(v) is int and 0<=v<=255 for v in value) and
                            all(abs(a-b)<= (24 if reference is RGB else 12) for a,b in zip(value,reference[marker])) and
                            type(clock) is int and max(0,marker*1_000_000-200_000)<=clock<=(marker+1)*1_000_000+200_000):matched.append(clock)
                    require(len(matched)>=2 and max(matched)-min(matched)>=100_000,'pixel_audio_pair_missing')
                    local.append(pcm_window(window,row,case,expected['phase'],marker))
            supported+=1;measurements.append(dict(caseId=case_id,windows=local))
        except (ValueError,KeyError,TypeError,OverflowError) as error:errors.append(str(error))
    if seen!=set(cases):errors.append('incomplete_rows')
    result['supportedRows']=supported;result['scopeAcceptance']=not errors and supported==len(planned)
    result['errors']=sorted(set(errors));return result
