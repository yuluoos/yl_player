"""Synthetic evidence mutations test the gate; these are not player observations."""
import base64, copy, hashlib, math, struct, unittest
from bound_av import validate
from run_bound_flutter_android import planned_controls
from run_bound_apple import CASES
from run_bound_flutter_apple import acceptance as apple_acceptance, planned_controls as apple_controls

class PublicControlPlanTest(unittest.TestCase):
    def test_exact_six_controls_required_before_launch(self):
        catalog=[dict(id=case,file=case,sha256='a'*64,audio={'channels':2}) for case in CASES]
        self.assertEqual({c['caseId'] for c in planned_controls(catalog)},set(CASES))
        for bad in [catalog[:-1],catalog+[catalog[0]],[]]:
            with self.assertRaises(ValueError):planned_controls(bad)
            with self.assertRaises(ValueError):apple_controls(bad)
        self.assertEqual({c['caseId'] for c in apple_controls(catalog)},set(CASES))

def tone(marker):
    return struct.pack('<16384f', *(v for i in range(8192) for v in
        (0.04*math.sin(2*math.pi*(440+marker*220+c*55)*i/48000) for c in range(2))))

class BoundAVTest(unittest.TestCase):
    def setUp(self):
        self.plan=dict(schema=1,runId='run-one',platform='macos',buildSha256='b'*64,testSha256='d'*64,
            artifactKind='apple-native-consumer',planned=[dict(caseId='mkv-avc-eac3',mediaHash='a'*64,channels=2)],
            phases=[dict(phase='play',markers=[0,1,2,3]),dict(phase='seek-1250',markers=[1]),dict(phase='seek-2250',markers=[2]),dict(phase='seek-0',markers=[0])])
        self.origin=dict(runId='run-one',sessionId='player-one',buildSha256='b'*64)
        self.row=dict(schema=1,**self.origin,platform='macos',testSha256='d'*64,caseId='mkv-avc-eac3',mediaHash='a'*64,
            identityVerified=True,outcome='passed',disposed=True,completed=True,releasedAudioBytes=0,phases=[])
        for phase in self.plan['phases']:
            pixels=[]; windows=[]
            for m in phase['markers']:
                raw=tone(m)
                for delta in (250000,450000):
                    pixels.append(dict(value=[[255,0,0],[0,255,0],[0,0,255],[255,255,255]][m],format='rgb8',audioClockUs=m*1000000+delta,hostTimeUs=10000000+m*1000000+delta))
                windows.append(dict(**self.origin,phase=phase['phase'],marker=m,rate=48000,channels=2,startUs=m*1000000+250000 if phase['phase']=='play' else int(phase['phase'].split('-')[1])*1000+100000,
                    frames=8192,pcmF32LE=base64.b64encode(raw).decode(),pcmSha256=hashlib.sha256(raw).hexdigest()))
            self.row['phases'].append(dict(**self.origin,phase=phase['phase'],pixels=pixels,pcmWindows=windows))
    def result(self,rows=None):return validate(self.plan,[self.row] if rows is None else rows)
    def test_real_values_can_accept_only_the_frozen_scope(self):
        result=self.result();self.assertTrue(result['scopeAcceptance']);self.assertFalse(result['fullAcceptance'])
    def test_mono_pcm_is_measured_without_inventing_a_second_channel(self):
        self.plan['planned'][0].update(channels=1,sourceChannels=1)
        for phase in self.row['phases']:
            for w in phase['pcmWindows']:
                values=struct.unpack('<16384f',base64.b64decode(w['pcmF32LE']))
                raw=struct.pack('<8192f',*values[::2])
                w.update(channels=1,pcmF32LE=base64.b64encode(raw).decode(),pcmSha256=hashlib.sha256(raw).hexdigest())
        self.assertTrue(self.result()['scopeAcceptance'])
    def test_http_requires_actual_source_binding_and_owned_server_receipt(self):
        self.plan['planned'][0]['transport']='http'
        self.assertFalse(self.result()['scopeAcceptance'])
        self.row.update(transport='http',sourceVerified=True,networkPolicy='managed',
            networkReceipt=dict(runId='run-one',mediaHash='a'*64,requests=2,bytesServed=100,rejected=0))
        self.assertTrue(self.result()['scopeAcceptance'])
        self.row['networkReceipt']['runId']='borrowed'
        self.assertFalse(self.result()['scopeAcceptance'])
    def test_android_mono_source_accepts_only_preserved_mono_or_duplicated_output(self):
        self.plan['platform']='android';self.plan['planned'][0]['sourceChannels']=1
        self.row.update(platform='android',audioOutputClosed=True,audioClockMethod='audiotrack-playback-head')
        for channels in (1,2):
            for phase in self.row['phases']:
                for w in phase['pcmWindows']:
                    mono=struct.unpack('<16384f',tone(w['marker']))[::2]
                    raw=struct.pack('<'+'f'*(8192*channels),*(v for x in mono for v in [x]*channels))
                    w.update(channels=channels,pcmF32LE=base64.b64encode(raw).decode(),pcmSha256=hashlib.sha256(raw).hexdigest())
            self.assertTrue(self.result()['scopeAcceptance'],channels)
    def test_missing_duplicate_or_unplanned_row_fails(self):
        for rows in [[],[self.row,self.row],[dict(self.row,caseId='another')]]:self.assertFalse(self.result(rows)['scopeAcceptance'])
    def test_run_build_test_and_media_cannot_be_borrowed(self):
        for key in ['runId','buildSha256','testSha256','mediaHash','platform']:
            row=copy.deepcopy(self.row);row[key]='wrong';self.assertFalse(self.result([row])['scopeAcceptance'],key)
    def test_nested_pcm_and_pixel_phase_identity_cannot_be_spliced(self):
        for key in ['runId','sessionId','buildSha256']:
            for target in ['phase','pcm']:
                row=copy.deepcopy(self.row);item=row['phases'][0]
                if target=='pcm':item=item['pcmWindows'][0]
                item[key]='other';self.assertFalse(self.result([row])['scopeAcceptance'])
    def test_lifecycle_and_runtime_identity_are_required(self):
        for key in ['identityVerified','completed','disposed']:
            row=dict(self.row);row[key]=False;self.assertFalse(self.result([row])['scopeAcceptance'])
    def test_hardware_failure_stays_required_and_is_not_support(self):
        self.row.update(outcome='failed',failureCode='decoder.video_hardware_unavailable',phases=[])
        r=self.result();self.assertEqual(1,r['requiredRows']);self.assertEqual(0,r['supportedRows']);self.assertFalse(r['scopeAcceptance'])
    def test_actual_pixels_and_audio_clock_are_required_together(self):
        for value in [None,-1,True,9000000]:
            row=copy.deepcopy(self.row)
            for p in row['phases'][0]['pixels']:p['audioClockUs']=value
            self.assertFalse(self.result([row])['scopeAcceptance'])
    def test_missing_seek_or_wrong_pixels_fails(self):
        row=copy.deepcopy(self.row);row['phases'].pop();self.assertFalse(self.result([row])['scopeAcceptance'])
        for p in self.row['phases'][0]['pixels']:p['value']=[0,0,0]
        self.assertFalse(self.result()['scopeAcceptance'])
    def test_raw_pcm_hash_and_tone_are_checked_not_a_boolean(self):
        for wrong in [b'broken',bytes(8192*2*4)]:
            row=copy.deepcopy(self.row);w=row['phases'][0]['pcmWindows'][0]
            w.update(pcmF32LE=base64.b64encode(wrong).decode(),pcmSha256=hashlib.sha256(wrong).hexdigest())
            self.assertFalse(self.result([row])['scopeAcceptance'])
    def test_nan_pcm_cannot_pass(self):
        raw=struct.pack('<16384f',*([float('nan')]*16384));w=self.row['phases'][0]['pcmWindows'][0]
        w.update(pcmF32LE=base64.b64encode(raw).decode(),pcmSha256=hashlib.sha256(raw).hexdigest())
        self.assertFalse(self.result()['scopeAcceptance'])
    def test_duplicate_window_or_changed_channel_count_fails(self):
        row=copy.deepcopy(self.row);row['phases'][0]['pcmWindows'].append(row['phases'][0]['pcmWindows'][0]);self.assertFalse(self.result([row])['scopeAcceptance'])
        self.row['phases'][0]['pcmWindows'][0]['channels']=6;self.assertFalse(self.result()['scopeAcceptance'])

    def test_malformed_documents_fail_closed(self):
        for plan in [None, [], dict(self.plan,planned=None), dict(self.plan,planned=[None])]:
            self.assertFalse(validate(plan,[])['scopeAcceptance'])
        for value in [None,[],1]:
            row=copy.deepcopy(self.row);row['phases']=[value]
            self.assertFalse(self.result([row])['scopeAcceptance'])
    def test_android_requires_actual_output_release_observation(self):
        self.plan['platform']='android';self.row['platform']='android'
        self.assertFalse(self.result()['scopeAcceptance'])
        self.row['audioOutputClosed']=True
        self.row['audioClockMethod']='audiotrack-playback-head'
        self.assertTrue(self.result()['scopeAcceptance'])

    def test_android_estimated_clock_cannot_claim_consumption(self):
        self.plan['platform']='android';self.row.update(platform='android',audioOutputClosed=True)
        for method in [None,'audiotrack-anchored-estimate']:
            self.row['audioClockMethod']=method
            self.assertFalse(self.result()['scopeAcceptance'])
    def test_stalled_consumption_after_seek_is_rejected(self):
        for pixel in self.row['phases'][1]['pixels']:pixel['audioClockUs']=1_500_000
        self.assertFalse(self.result()['scopeAcceptance'])

    def test_frozen_media3_route_requires_initialized_codec_identity(self):
        self.plan['planned'][0]['engine']='media3'
        self.assertFalse(self.result()['scopeAcceptance'])
        self.row.update(engine='media3',decoderMode='HARDWARE',decoderIdentity='c2.test.vp9',audioDecoderIdentity='c2.test.vorbis')
        self.assertTrue(self.result()['scopeAcceptance'])
        for key in ['engine','decoderMode','decoderIdentity','audioDecoderIdentity']:
            bad=copy.deepcopy(self.row);bad[key]=''
            self.assertFalse(self.result([bad])['scopeAcceptance'],key)

    def avplayer_pull_row(self):
        self.plan['artifactKind']='apple-public-flutter-debug-app'
        self.row.update(publicSessionId=self.row['sessionId'],publicApi='YlPlayerController/YlPlayerView',
            publicLifecycle=dict(created=True,ready=True,firstFrame=True,completed=True,disposed=True),
            pixelSource='flutter-native-view-display-layer',nativeViewAttached=True,
            audioClockMethod='avplayer-preeffects-source-pull',displayReadbackProtocol='paused-layer-timebase-v1',
            audioEvidenceBoundary='audio-queue-source-pull',avPlayerTapReleased=True,
            audioReadbackProtocol='continuous-source-pull-v1',
            windowVisibilityMethod='owned-all-spaces-window-v1')
        for epoch,phase in enumerate(self.row['phases']):
            phase['tapEpoch']=epoch
            for pixel in phase['pixels']:
                pixel.update(displayRate=0,windowVisible=True,tapEpoch=epoch,
                    pullStartUs=pixel['audioClockUs'],pullEndUs=pixel['audioClockUs']+50000,
                    pullFrames=2400,pullRate=48000)
        return dict(passed=True,identityVerified=True,artifactsUnchanged=True,runId=self.plan['runId'])

    def test_avplayer_render_pull_is_separate_from_played_sample_acceptance(self):
        status=self.avplayer_pull_row()
        result=apple_acceptance(self.plan,[self.row],status,True)
        self.assertFalse(result['scopeAcceptance'])
        self.assertTrue(result.get('renderPullAcceptance'))
        status['passed']=False
        self.assertFalse(apple_acceptance(self.plan,[self.row],status,True).get('renderPullAcceptance'))

    def test_render_pull_cannot_be_promoted_by_renaming_its_clock(self):
        self.avplayer_pull_row()
        self.row.update(audioClockMethod='renderer-paused-consumption',releasedAudioBytes=0)
        self.assertFalse(self.result()['scopeAcceptance'])

    def test_avplayer_render_pull_rejects_stale_epoch_invalid_range_and_unreleased_tap(self):
        status=self.avplayer_pull_row()
        for key,value in [('tapEpoch',99),('pullStartUs',0),('pullEndUs',-1),('pullFrames',True),('pullRate',0)]:
            bad=copy.deepcopy(self.row);bad['phases'][1]['pixels'][0][key]=value
            self.assertFalse(apple_acceptance(self.plan,[bad],status,True).get('renderPullAcceptance'),key)
        self.row['avPlayerTapReleased']=False
        self.assertFalse(apple_acceptance(self.plan,[self.row],status,True).get('renderPullAcceptance'))

    def test_apple_public_scope_requires_native_view_and_public_session(self):
        self.plan['artifactKind']='apple-public-flutter-debug-app'
        self.assertFalse(self.result()['scopeAcceptance'])
        self.row.update(publicSessionId=self.row['sessionId'],publicApi='YlPlayerController/YlPlayerView',
            publicLifecycle=dict(created=True,ready=True,firstFrame=True,completed=True,disposed=True),
            pixelSource='flutter-native-view-display-layer',nativeViewAttached=True,
            audioClockMethod='renderer-paused-consumption',displayReadbackProtocol='paused-layer-timebase-v1',
            windowVisibilityMethod='owned-all-spaces-window-v1')
        for phase in self.row['phases']:
            for pixel in phase['pixels']:pixel.update(displayRate=0,windowVisible=True)
        self.assertTrue(self.result()['scopeAcceptance'])
        status=dict(passed=True,identityVerified=True,artifactsUnchanged=True,runId=self.plan['runId'])
        self.assertTrue(apple_acceptance(self.plan,[self.row],status,True)['scopeAcceptance'])
        for key in status:
            bad=dict(status);bad[key]=False
            self.assertFalse(apple_acceptance(self.plan,[self.row],bad,True)['scopeAcceptance'],key)
        self.assertFalse(apple_acceptance(self.plan,[self.row],status,False)['scopeAcceptance'])
        for key,value in [('publicSessionId','other'),('pixelSource','native-test-texture'),('nativeViewAttached',False),('audioClockMethod','running-readback'),('displayReadbackProtocol',None),('displayReadbackProtocol','host-clock'),('windowVisibilityMethod',None)]:
            bad=copy.deepcopy(self.row);bad[key]=value
            self.assertFalse(self.result([bad])['scopeAcceptance'])
        for rate in [None,1,-1,True,'0']:
            bad=copy.deepcopy(self.row);bad['phases'][1]['pixels'][0]['displayRate']=rate
            self.assertFalse(self.result([bad])['scopeAcceptance'],rate)
        for visible in [None,False,1]:
            bad=copy.deepcopy(self.row);bad['phases'][1]['pixels'][0]['windowVisible']=visible
            self.assertFalse(self.result([bad])['scopeAcceptance'],visible)
        self.row['publicLifecycle']['disposed']=False
        self.assertFalse(self.result()['scopeAcceptance'])

    def test_public_scope_requires_matching_flutter_session_and_lifecycle(self):
        self.plan['artifactKind']='android-public-flutter-debug-apk'
        self.plan['platform']=self.row['platform']='android'
        self.row.update(audioClockMethod='audiotrack-playback-head',audioOutputClosed=True)
        self.assertFalse(self.result()['scopeAcceptance'])
        self.row.update(publicSessionId=self.row['sessionId'],publicApi='YlPlayerController/YlPlayerView',
            publicLifecycle=dict(created=True,ready=True,firstFrame=True,completed=True,disposed=True),
            pixelSource='flutter-repaint-boundary')
        self.assertTrue(self.result()['scopeAcceptance'])
        for key,value in [('publicSessionId','borrowed'),('pixelSource','native-image-reader'),('publicApi','native-only')]:
            bad=copy.deepcopy(self.row);bad[key]=value
            self.assertFalse(self.result([bad])['scopeAcceptance'],key)
        self.plan['platform']=self.row['platform']='macos'
        self.assertFalse(self.result()['scopeAcceptance'])
        self.plan['platform']=self.row['platform']='android'
        for key in self.row['publicLifecycle']:
            bad=copy.deepcopy(self.row);bad['publicLifecycle'][key]=False
            self.assertFalse(self.result([bad])['scopeAcceptance'],key)

if __name__=='__main__':unittest.main()
