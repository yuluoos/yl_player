#!/usr/bin/env python3
"""Prepare owned DASH media: frozen 40 seconds or explicit 120-second diagnostics."""
import argparse
import copy
import hashlib
from pathlib import Path
import xml.etree.ElementTree as ET

from network_profile import load_assets

SOURCE = Path(__file__).resolve().parents[2] / (
    'packages/yl_player/example/assets/test_media/dash_variants')
NS = 'urn:mpeg:dash:schema:mpd:2011'


def direct_playlists(root):
    """Independent direct-HTTP control for the owned two-rendition programme.

    Same MPD timelines, media and bandwidth declarations, no custom scheme or
    project media proxy. This is a diagnostic control, not a product exporter.
    """
    result = {}
    for rendition in range(3):
        lines = ['#EXTM3U', '#EXT-X-VERSION:7', '#EXT-X-PLAYLIST-TYPE:VOD',
                 '#EXT-X-TARGETDURATION:2' if rendition == 2 else '#EXT-X-TARGETDURATION:1',
                 '#EXT-X-MEDIA-SEQUENCE:0']
        for index, period in enumerate(root.findall(f'{{{NS}}}Period')):
            matches = [r for r in period.findall(f'{{{NS}}}AdaptationSet/{{{NS}}}Representation')
                       if (r.get('mimeType') == 'audio/mp4' if rendition == 2
                           else r.get('width') == ('320' if rendition == 0 else '640'))]
            if len(matches) != 1:
                raise ValueError('direct control requires the unchanged owned rendition set')
            representation = matches[0]
            template = representation.find(f'{{{NS}}}SegmentTemplate')
            prefix = period.find(f'{{{NS}}}BaseURL').text
            initial = template.get('initialization').replace('$RepresentationID$', representation.get('id'))
            media = template.get('media').replace('$RepresentationID$', representation.get('id'))
            if index:
                lines.append('#EXT-X-DISCONTINUITY')
            lines.append(f'#EXT-X-MAP:URI="{prefix}{initial}"')
            number = int(template.get('startNumber'))
            scale = int(template.get('timescale'))
            for segment in template.findall(f'{{{NS}}}SegmentTimeline/{{{NS}}}S'):
                for _ in range(int(segment.get('r', '0')) + 1):
                    lines.extend([f"#EXTINF:{int(segment.get('d')) / scale:.6f},",
                                  prefix + media.replace('$Number%05d$', f'{number:05d}')])
                    number += 1
        lines.append('#EXT-X-ENDLIST')
        result[f'direct-{rendition}.m3u8'] = ('\n'.join(lines) + '\n').encode()
    result['direct-master.m3u8'] = (
        '#EXTM3U\n#EXT-X-VERSION:7\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="1",URI="direct-2.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=414000,CODECS="avc1.42c01e,mp4a.40.2",RESOLUTION=320x180,AUDIO="audio"\ndirect-0.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=764000,CODECS="avc1.42c01e,mp4a.40.2",RESOLUTION=640x360,AUDIO="audio"\ndirect-1.m3u8\n'
    ).encode()
    return result


def create(output, missing_high_after=None, *, duration_seconds=40, direct_hls_control=False):
    if type(duration_seconds) is not int or duration_seconds not in (40, 120):
        raise ValueError('only frozen 40-second or diagnostic 120-second programmes are supported')
    if type(direct_hls_control) is not bool or (direct_hls_control and missing_high_after is not None):
        raise ValueError('direct control requires the complete rendition set')
    if missing_high_after is not None and (type(missing_high_after) is not int or
                                          not 2 <= missing_high_after <= 9):
        raise ValueError("missing boundary must follow two compatible Periods")
    output = Path(output)
    assets = load_assets(SOURCE)
    root = ET.fromstring(assets['manifest.mpd'])
    periods = root.findall(f'{{{NS}}}Period')
    if (root.attrib.get('mediaPresentationDuration') != 'PT8S' or
            len(periods) != 2 or
            any(p.attrib.get('duration') != 'PT4S' for p in periods)):
        raise ValueError('owned source programme changed; review before regeneration')
    for period in periods:
        root.remove(period)
    generated = {}
    for index in range(duration_seconds // 4):
        period = copy.deepcopy(periods[index % 2])
        period.set('id', f'network-period-{index}')
        period.set('start', f'PT{index * 4}S')
        prefix = f'network-period-{index}/'
        source_prefix = f'period{index % 2}/'
        base = period.find(f'{{{NS}}}BaseURL')
        if base is None or base.text != source_prefix:
            raise ValueError('owned source addressing changed')
        base.text = prefix
        for name, body in assets.items():
            if name.startswith(source_prefix) and name.endswith('.m4s'):
                generated[prefix + name.removeprefix(source_prefix)] = body
        if missing_high_after is not None and index >= missing_high_after:
            for adaptation in period.findall(f'{{{NS}}}AdaptationSet'):
                for representation in list(adaptation):
                    if representation.get('width') == '640':
                        adaptation.remove(representation)
                if adaptation.get('contentType') == 'video':
                    adaptation.set('maxWidth', '320')
                    adaptation.set('maxHeight', '180')
            for name in list(generated):
                if name.startswith(prefix) and (name.endswith('/init-1.m4s') or
                                                '/chunk-1-' in name):
                    del generated[name]
        root.append(period)
    root.set('mediaPresentationDuration', f'PT{duration_seconds}S')
    ET.register_namespace('', NS)
    ET.indent(root, space='  ')
    # Keep only this programme and its original media, not unrelated manifests.
    generated['manifest.mpd'] = ET.tostring(root, encoding='utf-8', xml_declaration=True)
    if direct_hls_control:
        generated.update(direct_playlists(root))
    output.mkdir(parents=True, exist_ok=False)
    for name, body in generated.items():
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(body)
    (output / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(body).hexdigest()}  ./{name}\n'
        for name, body in sorted(generated.items())))
    return dict(fixedMissingAtMs=missing_high_after*4000 if missing_high_after is not None else None,
                durationSeconds=duration_seconds, periodCount=duration_seconds // 4, assetCount=len(generated),
                sourceManifestSha256=hashlib.sha256(assets['manifest.mpd']).hexdigest(),
                manifestSha256=hashlib.sha256(generated['manifest.mpd']).hexdigest(),
                inventorySha256=hashlib.sha256((output / 'SHA256SUMS').read_bytes()).hexdigest())


if __name__ == '__main__':
    import json
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--missing-high-after', type=int)
    parser.add_argument('--duration-seconds', type=int, choices=(40, 120), default=40,
                        help='120 is a separate diagnostic, never a replacement for the frozen baseline')
    parser.add_argument('--direct-hls-control', action='store_true',
                        help='add a separate direct-HTTP HLS control; never replaces DASH acceptance')
    args = parser.parse_args()
    print(json.dumps(create(args.output, args.missing_high_after,
                            duration_seconds=args.duration_seconds,
                            direct_hls_control=args.direct_hls_control), sort_keys=True))
