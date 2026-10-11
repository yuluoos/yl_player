#!/usr/bin/env python3
"""Prepare a 40-second owned DASH programme without encoding any media."""
import argparse
import copy
import hashlib
from pathlib import Path
import xml.etree.ElementTree as ET

from network_profile import load_assets

SOURCE = Path(__file__).resolve().parents[2] / (
    'packages/yl_player/example/assets/test_media/dash_variants')
NS = 'urn:mpeg:dash:schema:mpd:2011'


def create(output):
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
    for index in range(10):
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
        root.append(period)
    root.set('mediaPresentationDuration', 'PT40S')
    ET.register_namespace('', NS)
    ET.indent(root, space='  ')
    # Keep only this programme and its original media, not unrelated manifests.
    generated['manifest.mpd'] = ET.tostring(root, encoding='utf-8', xml_declaration=True)
    output.mkdir(parents=True, exist_ok=False)
    for name, body in generated.items():
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(body)
    (output / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(body).hexdigest()}  ./{name}\n'
        for name, body in sorted(generated.items())))
    return dict(durationSeconds=40, periodCount=10, assetCount=len(generated),
                sourceManifestSha256=hashlib.sha256(assets['manifest.mpd']).hexdigest(),
                manifestSha256=hashlib.sha256(generated['manifest.mpd']).hexdigest(),
                inventorySha256=hashlib.sha256((output / 'SHA256SUMS').read_bytes()).hexdigest())


if __name__ == '__main__':
    import json
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(create(args.output), sort_keys=True))
