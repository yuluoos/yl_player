"""R16 source-copy/declaration proof, distinct from R14 behavior comparison."""
from pathlib import Path
from historical_migration import frozen_tree

FIXTURE = Path(__file__).with_name('historical_origins')
MANIFEST_SHA256 = '748be90b8179d239052ea8658aa6af16150e5609900620275d62a3523720bb43'
ORIGIN = '81d261c445f70df09f18458707ba1e8eb1e2d71f'


def origin_tree(fixture=FIXTURE):
    return frozen_tree(fixture, manifest_digest=MANIFEST_SHA256, origin=ORIGIN)


def verify_historical(fixture=FIXTURE):
    from source_parity import compare
    with origin_tree(fixture) as root:
        compare(root)
