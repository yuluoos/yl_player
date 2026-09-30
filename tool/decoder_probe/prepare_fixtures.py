"""Regenerate test-only compressed fixtures with a host FFmpeg, never shipped."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / 'packages/yl_player/example/assets/test_media/format_matrix'
OUT = Path(__file__).resolve().parent / 'fixtures'


def unpack_hex(text):
    return bytes.fromhex(''.join(line.split(': ', 1)[1].split('  ', 1)[0].replace(' ', '')
                                for line in text.splitlines() if ': ' in line))


def extract(path, case):
    data = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_streams', '-show_packets', '-show_data', '-of', 'json', str(path)]))
    stream = data['streams'][0]
    assert stream['codec_name'] in ('h264', 'av1')
    assert stream['width'] == 320 and stream['height'] == 180
    packets = data['packets']; assert 1 <= len(packets) <= 96
    return dict(caseId=case, codec=stream['codec_name'], width=stream['width'], height=stream['height'],
                profile=stream['profile'], bitDepth=10 if stream['pix_fmt'] == 'yuv420p10le' else 8,
                configuration=base64.b64encode(unpack_hex(stream['extradata'])).decode(),
                frames=[dict(data=base64.b64encode(unpack_hex(p['data'])).decode(),
                    ptsUs=round(float(p['pts_time'])*1_000_000),
                    durationUs=round(float(p['duration_time'])*1_000_000)) for p in packets])


def main():
    OUT.mkdir(exist_ok=True)
    original = MEDIA / 'mkv-av1-opus.mkv'
    with tempfile.TemporaryDirectory(prefix='yl-av1-owned-') as temp:
        ten = Path(temp) / 'main10.mkv'
        args = ['-map', '0:v:0', '-an', '-t', '1', '-c:v', 'libsvtav1', '-preset', '12', '-crf', '35',
                '-pix_fmt', 'yuv420p10le', '-svtav1-params', 'lp=2']
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(original), *args, '-y', str(ten)], check=True)
        manifest = dict(sourceLicense='owned-generated project color/tone fixtures',
            ffmpegVersion=subprocess.check_output(['ffmpeg', '-version'],text=True).splitlines()[0],
            tenBitDerivation='Re-encode the owned 8-bit video to 10-bit sample storage; not a native 10-bit precision or HDR reference.',
            tenBitArguments=args, cases=[])
        for case, path in [('avc-control', MEDIA/'mp4-avc-aac.mp4'), ('av1-main8', original), ('av1-main10', ten)]:
            fixture=extract(path,case)
            result=OUT/(case+'.json');result.write_text(json.dumps(fixture,separators=(',',':'))+'\n')
            # Independent software decode confirms the input is a valid stream, not VT support.
            subprocess.run(['ffmpeg','-v','error','-i',str(path),'-map','0:v:0','-f','null','-'],check=True)
            manifest['cases'].append(dict(caseId=case, fixture=result.name,
                sha256=hashlib.sha256(result.read_bytes()).hexdigest(),
                containerSha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                ownedSource=str((original if case=='av1-main10' else path).relative_to(ROOT)),
                ownedSourceSha256=hashlib.sha256((original if case=='av1-main10' else path).read_bytes()).hexdigest(),
                frames=len(fixture['frames']),bitDepth=fixture['bitDepth'],profile=fixture['profile'],width=320,height=180))
        (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

if __name__ == '__main__': main()
