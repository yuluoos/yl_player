"""Exercise actual native PCM storage, including empty untimed source failures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Diagnostics/YlBoundAvPlayerAudio.swift'

@unittest.skipUnless(os.uname().sysname=='Darwin','Apple audio tap storage')
class AudioPullTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.build.cleanup)
        folder=Path(cls.build.name)
        (folder/'main.swift').write_text('''import AVFoundation
import MediaToolbox
let storage = YlBoundAvPlayerAudio.Storage()
storage.format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
  mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
  mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
let mode = CommandLine.arguments[1]
let range = CMTimeRange(start: .zero, duration: CMTime(value: 256, timescale: 48000))
var samples = [Float](repeating: 0.25, count: 512)
samples.withUnsafeMutableBytes { bytes in
  var buffers = AudioBufferList(mNumberBuffers: 1,
    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
  storage.record(status: -1, buffers: &buffers,
    frames: mode == "nonempty" ? 256 : 0, range: mode == "timed" ? range : .invalid)
  storage.record(status: noErr, buffers: &buffers, frames: 256, range: range)
}
let blocks = storage.blocks
let value: [String: Any] = ["drops": storage.drops, "blocks": blocks.count,
  "frames": blocks.first?.samples.first?.count ?? 0, "sample": blocks.first?.samples.first?.first ?? 0]
print(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!)
''')
        cls.executable=folder/'test'
        subprocess.run(['xcrun','swiftc','-D','DEBUG','-D','YL_BOUND_AV',str(SOURCE),str(folder/'main.swift'),'-o',str(cls.executable)],check=True,capture_output=True)
    def invoke(self,mode):
        return json.loads(subprocess.check_output([str(self.executable),mode],text=True))
    def test_empty_untimed_error_does_not_erase_real_pcm(self):
        result=self.invoke('empty')
        self.assertEqual(dict(drops=0,blocks=1,frames=256,sample=0.25),result)
    def test_error_with_a_media_interval_still_invalidates_evidence(self):
        result=self.invoke('timed');self.assertEqual(1,result['drops']);self.assertEqual(0,result['blocks'])
    def test_error_with_frames_still_invalidates_evidence(self):
        result=self.invoke('nonempty');self.assertEqual(1,result['drops']);self.assertEqual(0,result['blocks'])

if __name__=='__main__':unittest.main()
