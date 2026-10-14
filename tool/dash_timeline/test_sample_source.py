"""Compare production in-memory demux to independently probed raw MP4 ticks."""
from fractions import Fraction
import json,os,shutil,subprocess,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
SHARED=ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared'
MEDIA=ROOT/'packages/yl_player/example/assets/test_media/dash_timeline'
class SampleSourceTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='darwin' and shutil.which('xcrun') and shutil.which('ffprobe'), 'requires Swift and FFmpeg reference probe')
    def test_original_packet_times_and_ownership(self):
        framework=Path(os.environ.get('YL_DASH_FRAMEWORK_PATH',ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64'))
        with tempfile.TemporaryDirectory(prefix='yl-dash-samples-') as folder:
            out=Path(folder); main=out/'main.swift'; main.write_bytes((Path(__file__).parent/'sample_source_tests.swift').read_bytes())
            support=out/'support.swift'; support.write_text((Path(__file__).parent/'program_resource_support.swift').read_text().replace('let message: String','let message: String\n  var diagnostic: String? = nil'))
            sources=[SHARED/'DASH'/name for name in ['YlDashDocument.swift','YlDashSidx.swift','YlDashProgramTime.swift','YlDashProgramTimeline.swift','YlDashProgramDocument.swift','YlDashProgramResources.swift','YlDashSampleSource.swift']]
            sources += [SHARED/name for name in ['Dependencies/YlOpenCancellationToken.swift','Dependencies/YlNetworkConfiguration.swift','Network/YlManagedRequestPolicy.swift','Network/YlOriginCredentialPolicy.swift','FFmpeg/YlManagedBufferLedger.swift','FFmpeg/YlBoundedBufferPlan.swift']]
            build=subprocess.run(['xcrun','swiftc','-module-cache-path',str(out/'cache'),'-F',str(framework),'-framework','YlFFmpegBridge','-Xlinker','-rpath','-Xlinker',str(framework),*map(str,sources),str(support),str(main),'-o',str(out/'tests')],capture_output=True,text=True,timeout=120)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            run=subprocess.run([str(out/'tests'),str(MEDIA)],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            rows=json.loads(run.stdout); self.assertEqual(len(rows),8)
            total=0
            for row in rows:
                directory=MEDIA/row['directory']; track=row['track']; number=row['fragment']; file=out/'reference.mp4'
                file.write_bytes((directory/f'init-{track}.m4s').read_bytes()+(directory/f'chunk-{track}-{number:05d}.m4s').read_bytes())
                reference=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_packets','-show_streams','-of','json',str(file)]))
                base=Fraction(reference['streams'][0]['time_base'])
                expected=[(p['pts']*base,p['duration']*base) for p in reference['packets']]
                actual=[(Fraction(p[0],p[1]),Fraction(p[2],p[3])) for p in row['packets']]
                self.assertEqual(actual,expected,(row['directory'],track,number));total+=len(actual)
            print(f'Original packet clocks + lifetime checks: {total} packets / {len(rows)} fragments')
