#!/usr/bin/env python3
"""Add owned cross-codec/track-catalog fixtures without regenerating prior media."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
from generate_fixture import OUT, period, mpd


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=OUT)
    target = parser.parse_args().output
    folder = target / 'hevc'
    folder.mkdir(parents=True, exist_ok=True)
    args = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
            'color=c=yellow:s=640x360:r=24:d=4,drawbox=color=cyan:t=fill:enable=gte(t\\,1)',
            '-c:v', 'libx265', '-preset', 'veryfast', '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1',
            '-x265-params', 'keyint=24:min-keyint=24:scenecut=0:open-gop=0:bframes=3:pools=1:frame-threads=1:log-level=error',
            '-f', 'dash', '-seg_duration', '1', '-use_template', '1', '-use_timeline', '1',
            '-init_seg_name', 'init-$RepresentationID$.m4s',
            '-media_seg_name', 'chunk-$RepresentationID$-$Number%05d$.m4s', str(folder / 'generated.mpd')]
    subprocess.run(args, check=True)
    encoded = ET.parse(folder / 'generated.mpd')
    ns = {'d': 'urn:mpeg:dash:schema:mpd:2011'}
    representation = encoded.find('.//d:Representation', ns)
    codec = representation.attrib['codecs']
    assert codec == 'hvc1' or codec.startswith('hvc1.'), codec
    template = encoded.find('.//d:SegmentTemplate', ns)
    assert template.attrib['timescale'] == '12288'
    entries = template.findall('d:SegmentTimeline/d:S', ns)
    assert sum(int(s.attrib['d']) * (int(s.attrib.get('r', '0')) + 1) for s in entries) == 49152
    (folder / 'generated.mpd').unlink()
    first = period(0, 0, 1.5).replace('<AdaptationSet contentType="audio"', '<AdaptationSet id="main" contentType="audio"')
    second = period(1, 1.5, 1.5).replace('<AdaptationSet contentType="audio"', '<AdaptationSet id="main" contentType="audio"')
    hevc = second.replace('<BaseURL>period1/</BaseURL>', '<BaseURL>hevc/</BaseURL>')
    hevc = hevc.replace('codecs="avc1.42c01e" width="320" height="180" bandwidth="350000"',
                        f'codecs="{codec}" width="640" height="360" bandwidth="650000"')
    hevc = hevc.replace('initialization="init-1.m4s"', 'initialization="../period1/init-1.m4s"')
    hevc = hevc.replace('media="chunk-1-', 'media="../period1/chunk-1-')
    (target / 'cross-codec.mpd').write_text(mpd([first, hevc], 3) + '\n')
    avc_folder = target / 'avc'
    avc_folder.mkdir(parents=True, exist_ok=True)
    avc_args = args[:args.index('-c:v')] + ['-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
        '-x264-params', 'keyint=24:min-keyint=24:scenecut=0:open-gop=0:bframes=3:threads=1',
        *args[args.index('-f', args.index('-c:v')):-1], str(avc_folder / 'generated.mpd')]
    subprocess.run(avc_args, check=True)
    avc_codec = ET.parse(avc_folder / 'generated.mpd').find('.//d:Representation', ns).attrib['codecs']
    (avc_folder / 'generated.mpd').unlink()
    resolution = hevc.replace('<BaseURL>hevc/</BaseURL>', '<BaseURL>avc/</BaseURL>').replace(f'codecs="{codec}"', f'codecs="{avc_codec}"')
    (target / 'resolution.mpd').write_text(mpd([first, resolution], 3) + '\n')
    audio_start = second.index('<AdaptationSet id="main"')
    audio_end = second.index('</AdaptationSet>', audio_start) + len('</AdaptationSet>')
    commentary = second[audio_start:audio_end].replace('id="main"', 'id="commentary"')
    commentary = commentary.replace('<Representation', '<Role schemeIdUri="urn:mpeg:dash:role:2011" value="commentary"/><Representation', 1)
    added = second.replace('</Period>', commentary + '</Period>')
    (target / 'audio-added.mpd').write_text(mpd([first, added], 3) + '\n')
    removed = second[:audio_start] + commentary + second[audio_end:]
    (target / 'audio-removed.mpd').write_text(mpd([first, removed], 3) + '\n')
    paths = sorted(folder.glob('*.m4s')) + sorted(avc_folder.glob('*.m4s')) + [target / n for n in ['cross-codec.mpd', 'resolution.mpd', 'audio-added.mpd', 'audio-removed.mpd']]
    provenance = {'ffmpeg': subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0],
                  'command': args, 'files': {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    # Do not embed the invocation's output directory into portable provenance.
    provenance['command'][-1] = 'hevc/generated.mpd'
    avc_args[-1] = 'avc/generated.mpd'
    provenance['avc_command'] = avc_args
    (target / 'period-fixture-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')

if __name__ == '__main__':
    main()
