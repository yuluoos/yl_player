"""Cut finite length controls from the existing owned continuous fixture."""
import json
from pathlib import Path
import subprocess
from run_audio_integration_resources import ROOT, digest

DIRECTORY = ROOT/'packages/yl_player/example/build/resource-length-fixtures'
LENGTHS = (4, 30, 60)


def generate():
    source = ROOT/'packages/yl_player/example/assets/test_media/format_matrix/continuous-avc-aac.mkv'
    DIRECTORY.mkdir(parents=True, exist_ok=False)
    result = dict(source=str(source.relative_to(ROOT)), sourceSHA256=digest(source),
                  ffmpeg=subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0], fixtures=[])
    for seconds in LENGTHS:
        output = DIRECTORY/f'decoded-{seconds}.mkv'
        command = ['ffmpeg', '-v', 'error', '-n', '-i', str(source), '-t', str(seconds),
                   '-map', '0:v:0', '-map', '0:a:0', '-c', 'copy', str(output)]
        subprocess.run(command, check=True, timeout=30)
        probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-count_packets',
            '-show_streams', '-show_format', '-of', 'json', str(output)], text=True, timeout=30))
        assert abs(float(probe['format']['duration']) - seconds) < .3
        assert [s['codec_name'] for s in probe['streams']] == ['h264', 'aac']
        assert probe['streams'][1]['sample_rate'] == '48000' and probe['streams'][1]['channels'] == 2
        result['fixtures'].append(dict(seconds=seconds, path=str(output.relative_to(ROOT)),
            sha256=digest(output), bytes=output.stat().st_size, command=command, probe=probe))
    (DIRECTORY/'manifest.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({r['seconds']: r['probe']['streams'][1]['nb_read_packets'] for r in result['fixtures']}))


if __name__ == '__main__': generate()
