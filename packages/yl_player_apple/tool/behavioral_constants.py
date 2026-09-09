"""Compatibility entrypoint for the historical migration proof (R14)."""
from pathlib import Path
import runpy

if __name__ == '__main__':
    import sys
    gate = Path(__file__).resolve().parents[3] / 'tool/consumer_fixtures/apple_flutter'
    sys.path.insert(0, str(gate))
    runpy.run_path(str(gate / 'behavioral_constants.py'), run_name='__main__')
