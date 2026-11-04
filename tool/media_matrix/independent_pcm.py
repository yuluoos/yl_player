"""Packet identity and unshifted PCM comparison for independent audio references."""
from fractions import Fraction
import hashlib
import json
import subprocess


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_packets(path, audio_index=0):
    metadata = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', f'a:{audio_index}', '-show_packets', '-show_streams',
        '-show_entries', 'packet=pts,size,data_hash:stream=time_base', '-show_data_hash', 'sha256',
        '-of', 'json', str(path)]))
    stream = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(path), '-map', f'0:a:{audio_index}',
                                      '-c:a', 'copy', '-f', 'data', '-'])
    time_base = Fraction(metadata['streams'][0]['time_base'])
    packets = []
    offset = 0
    timestamps = []
    for row in metadata['packets']:
        timestamps.append(row['pts'] * time_base)
        size = int(row['size'])
        packet = stream[offset:offset + size]
        assert 'SHA256:' + sha(packet) == row['data_hash']
        packets.append(packet)
        offset += size
    assert offset == len(stream)
    return timestamps, packets


def compare(actual, reference, start, channels, divisor, limit):
    samples = reference[start * channels:start * channels + len(actual)]
    assert start >= 0 and len(samples) == len(actual) and len(actual) % channels == 0
    # A NaN fails the explicit comparison even if other samples are finite.
    errors = [0.0] * channels
    for i, (value, expected) in enumerate(zip(actual, samples)):
        delta = abs(value - expected / divisor)
        if not delta < limit:
            raise ValueError(f'frame {start + i // channels}, channel {i % channels}: error {delta}')
        errors[i % channels] = max(errors[i % channels], delta)
    return errors
