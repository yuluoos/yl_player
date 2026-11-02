import unittest
from acoustic_evidence import inspect, PROTOCOL, MEDIA, COLORS


def fixture():
    phases = [('play', 0), ('seek-1250', 1), ('seek-2250', 2), ('seek-0', 0)]
    plan = dict(platform='macos', planned=[{}], runId='run',
                acoustic=dict(protocol=PROTOCOL, helperSha256='1'*64),
                phases=[dict(phase=name, markers=list(range(4)) if name=='play' else [first])
                        for name,first in phases])
    phases_out = []
    records = [dict(runId='run', ready=True, builtinInput=True, builtinOutput=True)]
    def window(i, marker=None):
        bands = [0.0]*8
        if marker is not None:
            bands[2*marker] = 0.4
        records.append(dict(runId='run', sample=1920*i, frames=1920, rate=48000,
                            hostUs=40000*i, bands=bands))
    i = 0
    for i in range(8):
        window(i)
    i += 1
    for name, first in phases:
        pixels = []
        for tag in (range(4) if name=='play' else (first, first+1)):
            for _ in range(25):
                window(i, tag)
                pixels.append(dict(hostTimeUs=40000*i+20000, format='rgb8', value=list(COLORS[tag])))
                i += 1
        phases_out.append(dict(phase=name, pixels=pixels))
    records.append(dict(runId='run', ended=True))
    row = dict(runId='run', publicSessionId='session', caseId='mp4-avc-aac', transport='file',
               mediaHash=MEDIA, phases=phases_out, acoustic=dict(runId='run', sessionId='session',
               helperSha256='1'*64, launchUs=320000, records=records))
    return plan,row


class AcousticEvidenceTests(unittest.TestCase):
    def test_independent_transition_and_pixel_pairs_in_every_phase(self):
        plan,row = fixture()
        self.assertEqual(7,len(inspect(plan,row)))

    def test_audio_from_other_run_or_missing_samples_cannot_qualify(self):
        for change in ('identity','gap','silence','missing_transition','overlap','wrong_pixels'):
            with self.subTest(change=change):
                plan,row = fixture()
                windows = row['acoustic']['records']
                if change=='identity':
                    windows[30]['runId']='other'
                elif change=='gap':
                    del windows[20:24]
                elif change=='silence':
                    windows[5]['bands'][0]=0.4
                elif change=='missing_transition':
                    for w in windows[-26:-1]:
                        w['bands']=[0.4]+[0]*7
                elif change=='overlap':
                    row['phases'][-1]['pixels'] = row['phases'][0]['pixels']
                else:
                    for pixel in row['phases'][0]['pixels']:
                        pixel['value']=[0,0,0]
                with self.assertRaises(ValueError):
                    inspect(plan,row)


if __name__=='__main__':
    unittest.main()
