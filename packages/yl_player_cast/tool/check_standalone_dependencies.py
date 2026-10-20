#!/usr/bin/env python3
"""Resolve a real standalone Cast consumer and reject native player dependencies."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='yl-cast-consumer-') as temporary:
    root = Path(temporary)
    overrides = []
    for name in ['yl_player_cast', 'yl_player_platform_interface']:
        package = repo / 'packages' / name
        manifest = package / 'pubspec.yaml'
        if not manifest.exists():
            continue
        target = root / package.name
        target.mkdir()
        # Detached copies prevent workspace resolution from masking dependencies.
        text = manifest.read_text().replace('resolution: workspace\n', '')
        (target / 'pubspec.yaml').write_text(text)
        if (package / 'lib').exists():
            shutil.copytree(package / 'lib', target / 'lib')
        overrides.append(f'  {package.name}:\n    path: {target}\n')
    consumer = root / 'consumer'
    consumer.mkdir()
    (consumer / 'pubspec.yaml').write_text(
        'name: standalone_dlna_consumer\npublish_to: none\n'
        'environment:\n  sdk: ^3.12.0\n'
        'dependencies:\n  flutter:\n    sdk: flutter\n'
        '  yl_player_cast: ^0.3.0-dev.3\n'
        '  yl_player_platform_interface: ^0.3.0-dev.3\n'
        'dev_dependencies:\n  flutter_test:\n    sdk: flutter\n'
        'dependency_overrides:\n' + ''.join(overrides)
    )
    flutter = os.environ.get('FLUTTER', 'flutter')
    subprocess.run([flutter, 'pub', 'get', '--offline', '--no-example'],
                   cwd=consumer, check=True)
    result = subprocess.run([flutter, 'pub', 'deps', '--json'], cwd=consumer,
                            check=True, capture_output=True, text=True)
    graph = json.loads(result.stdout)
    packages = {package['name']: package for package in graph['packages']}
    reached = set()
    pending = ['standalone_dlna_consumer']
    while pending:
        name = pending.pop()
        if name in reached:
            continue
        reached.add(name)
        pending.extend(packages[name]['dependencies'])
    forbidden = {
        'yl_player', 'yl_player_apple', 'yl_player_android',
        'yl_player_media_core', 'yl_player_media_delivery',
        'yl_player_cast_player_adapter',
    }
    leaked = sorted(reached & forbidden)
    if leaked:
        raise SystemExit(f'Cast pulls optional playback dependencies: {leaked}')
    print('Standalone DLNA dependency graph excludes player/native delivery:',
          ', '.join(sorted(reached)))
    shutil.copytree(repo / 'packages/yl_player_cast/test', consumer / 'test')
    subprocess.run([flutter, 'test', '--no-pub'], cwd=consumer, check=True)
