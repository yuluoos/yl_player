#!/usr/bin/env python3
"""Generate owned, separately encoded compatible AVC ladders; no downloaded media."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'packages/yl_player/example/assets/test_media/dash_variants'
NS = 'urn:mpeg:dash:schema:mpd:2011'
ET.register_namespace('', NS)

def tag(name):
    return f'{{{NS}}}{name}'

with tempfile.TemporaryDirectory(prefix='yl-dash-variants-') as work:
    work = Path(work)
    mpd = ET.Element(tag('MPD'), type='static', mediaPresentationDuration='PT8S', minBufferTime='PT1S')
    for index, frequency in enumerate([440, 660]):
        directory = work / f'period{index}'
        directory.mkdir()
        subprocess.run([
            'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
            '-f', 'lavfi', '-i', 'testsrc=size=320x180:rate=24:duration=4',
            '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=24:duration=4',
            '-f', 'lavfi', '-i', f'sine=frequency={frequency}:sample_rate=48000:duration=4',
            '-map', '0:v', '-map', '1:v', '-map', '2:a',
            '-c:v', 'libx264', '-preset', 'veryfast', '-profile:v', 'baseline', '-level:v', '3.0',
            '-pix_fmt', 'yuv420p', '-g', '24', '-keyint_min', '24', '-sc_threshold', '0',
            '-b:v:0', '350k', '-b:v:1', '700k', '-c:a', 'aac', '-b:a', '64k', '-ar', '48000', '-ac', '1',
            '-f', 'dash', '-seg_duration', '1', '-use_template', '1', '-use_timeline', '1',
            '-adaptation_sets', 'id=0,streams=v id=1,streams=a',
            '-init_seg_name', 'init-$RepresentationID$.m4s',
            '-media_seg_name', 'chunk-$RepresentationID$-$Number%05d$.m4s',
            str(directory / 'generated.mpd'),
        ], check=True)
        generated = ET.parse(directory / 'generated.mpd').getroot()
        period = generated.find(tag('Period'))
        period.set('id', f'period{index}')
        period.set('start', f'PT{index * 4}S')
        period.set('duration', 'PT4S')
        base = ET.Element(tag('BaseURL')); base.text = f'period{index}/'
        period.insert(0, base)
        if index == 1:
            video = period.find(tag('AdaptationSet'))
            representations = video.findall(tag('Representation'))
            for rep in representations:
                old_id = rep.attrib['id']
                rep.set('id', f'second-{old_id}')
                template = rep.find(tag('SegmentTemplate'))
                for attr in ['initialization', 'media']:
                    template.set(attr, template.attrib[attr].replace('$RepresentationID$', old_id))
                video.remove(rep)
            for rep in reversed(representations):
                video.append(rep)
        mpd.append(period)
        (directory / 'generated.mpd').unlink()
    ET.indent(mpd, space='  ')
    (work / 'manifest.mpd').write_bytes(ET.tostring(mpd, encoding='utf-8', xml_declaration=True))
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for path in work.rglob('*'):
        if path.is_file():
            destination = OUTPUT / path.relative_to(work)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(path.read_bytes())
    files = sorted(p for p in OUTPUT.rglob('*') if p.is_file() and p.name not in ['README.md', 'SHA256SUMS'])
    (OUTPUT / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  ./{p.relative_to(OUTPUT)}\n' for p in files))
