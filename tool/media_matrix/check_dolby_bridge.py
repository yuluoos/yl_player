#!/usr/bin/env python3
"""Exercise the installed/candidate Dolby ABI with real owned packets.

Host FFmpeg reference is a separate build, not independent decoder ancestry.
The native Apple integration tests additionally verify trim, layout and switching.
"""
import argparse
import array
import ctypes as c
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

class MediaInfo(c.Structure):
    _fields_ = [('stream_count', c.c_int32), ('duration_us', c.c_int64)]

class StreamInfo(c.Structure):
    _fields_ = [(name, c.c_int32) for name in
                ('index', 'kind', 'codec', 'width', 'height', 'sample_rate', 'channel_count')] + [
                    ('duration_us', c.c_int64), ('time_base_num', c.c_int32),
                    ('time_base_den', c.c_int32), ('channel_layout_mask', c.c_uint64)]

def check_discovery(lib, path, expected):
    """Use production probing; never synthesize a speaker mask from a count."""
    lib.ylf_open_local.argtypes = [c.c_char_p, c.POINTER(c.c_void_p), c.POINTER(MediaInfo)]
    lib.ylf_copy_stream_info.argtypes = [c.c_void_p, c.c_int32, c.POINTER(StreamInfo)]
    lib.ylf_close.argtypes = [c.POINTER(c.c_void_p)]
    context, media = c.c_void_p(), MediaInfo()
    assert lib.ylf_open_local(str(path.resolve()).encode(), c.byref(context), c.byref(media)) == 0
    try:
        for index, codec, channels, mask in expected:
            stream = StreamInfo()
            assert lib.ylf_copy_stream_info(context, index, c.byref(stream)) == 0
            actual = (stream.codec, stream.sample_rate, stream.channel_count, stream.channel_layout_mask)
            assert actual == (codec, 48000, channels, mask), (path.name, index, actual)
    finally:
        lib.ylf_close(c.byref(context))
    return len(expected) * 2 + 1

def run(framework):
    lib = c.CDLL(str(framework.resolve()))
    lib.ylf_dolby_create.argtypes = [c.c_int32, c.c_int32, c.c_int32, c.c_uint64]
    lib.ylf_dolby_create.restype = c.c_void_p
    lib.ylf_dolby_decode.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_float), c.c_int32, c.POINTER(c.c_int32)]
    lib.ylf_dolby_decode.restype = c.c_int32
    for name in ['ylf_dolby_reset', 'ylf_dolby_free']:
        getattr(lib,name).argtypes=[c.c_void_p]
        getattr(lib,name).restype=None
    assert not lib.ylf_dolby_create(0,48000,2,3)
    assert not lib.ylf_dolby_create(6,48000,6,3)
    cases=[('mkv-avc-ac3-51',6,6,0x60f),('mkv-avc-eac3',7,2,3)]
    checks=2
    media_root = ROOT/'packages/yl_player/example/assets/test_media'
    for name, codec, channels, mask in cases:
        checks += check_discovery(lib, media_root/'format_matrix'/f'{name}.mkv', [(1,codec,channels,mask)])
    checks += check_discovery(lib, media_root/'pcm_alignment/p03-pcm-switch.mkv', [(1,6,6,0x60f),(2,7,2,3)])
    for name,codec,channels,mask in cases:
        path=ROOT/'packages/yl_player/example/assets/test_media/format_matrix'/f'{name}.mkv'
        probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','a','-show_packets','-show_data','-of','json',str(path)]))
        packets=[b''.join(bytes.fromhex(line.split(': ')[1].split('  ')[0]) for line in item['data'].strip().splitlines()) for item in probe['packets']]
        expected=array.array('f',subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-map','0:a:0','-f','f32le','-']))
        decoder=lib.ylf_dolby_create(codec,48000,channels,mask)
        assert decoder, (name,'create')
        try:
            samples=(c.c_float*(1536*channels))(); frames=c.c_int32()
            # Reject preconditions before consuming input; subsequent PCM remains exact.
            assert lib.ylf_dolby_decode(decoder,packets[0],len(packets[0]),samples,1535,c.byref(frames)) != 0
            assert frames.value==0
            assert lib.ylf_dolby_decode(decoder,packets[0],65537,samples,1536,c.byref(frames)) != 0
            checks+=3
            first=None
            for repeat in range(2):
                actual=[]
                for packet in packets:
                    assert lib.ylf_dolby_decode(decoder,packet,len(packet),samples,1536,c.byref(frames))==0
                    assert frames.value==1536
                    actual.extend(samples[:frames.value*channels]); checks+=2
                assert len(actual)==len(expected)==192000*channels
                peak=max(abs(a-b) for a,b in zip(actual,expected))
                assert peak<0.0002,(name,repeat,peak)
                if first is None: first=actual[:1536*channels]
                lib.ylf_dolby_reset(decoder);checks+=2
                print(json.dumps(dict(codec=name,repeat=repeat,frames=len(actual)//channels,channels=channels,peakError=peak)))
            assert lib.ylf_dolby_decode(decoder,b'broken',6,samples,1536,c.byref(frames)) != 0
            assert lib.ylf_dolby_decode(decoder,packets[0],len(packets[0]),samples,1536,c.byref(frames)) != 0
            lib.ylf_dolby_reset(decoder)
            assert lib.ylf_dolby_decode(decoder,packets[0],len(packets[0]),samples,1536,c.byref(frames))==0
            assert list(samples[:frames.value*channels])==first
            checks+=4
        finally:
            lib.ylf_dolby_free(decoder)
    print(f'{checks} Dolby ABI checks passed')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('framework',type=Path)
    run(parser.parse_args().framework)
