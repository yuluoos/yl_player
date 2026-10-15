#!/usr/bin/env python3
"""Add CodecDelay to an owned test MKV, rebuilding sizes and removing indexes.

This is test-only EBML editing, never a production demuxer. Packet bytes and
cluster timestamps stay intact, so the demuxer's delay projection is exercised.
"""
from pathlib import Path
import sys


def vint(data, offset, *, identifier=False):
    first = data[offset]
    if not first:
        raise ValueError('invalid EBML vint')
    width = 1
    while not first & (0x80 >> (width - 1)):
        width += 1
    if offset + width > len(data):
        raise ValueError('truncated EBML vint')
    value = int.from_bytes(data[offset:offset + width], 'big')
    if not identifier:
        value &= (1 << (7 * width)) - 1
        if value == (1 << (7 * width)) - 1:
            value = None
    return value, width


def elements(data):
    offset = 0
    while offset < len(data):
        identifier, id_width = vint(data, offset, identifier=True)
        size, size_width = vint(data, offset + id_width)
        start = offset + id_width + size_width
        end = len(data) if size is None else start + size
        if end > len(data):
            raise ValueError('truncated EBML element')
        yield identifier, data[start:end]
        offset = end


def element(identifier, payload):
    raw_id = identifier.to_bytes((identifier.bit_length() + 7) // 8, 'big')
    for width in range(1, 9):
        if len(payload) < (1 << (7 * width)) - 1:
            size = ((1 << (7 * width)) | len(payload)).to_bytes(width, 'big')
            return raw_id + size + payload
    raise ValueError('fixture too large')


def with_delay(data, nanoseconds):
    found = 0
    output = bytearray()
    for identifier, payload in elements(data):
        if identifier == 0x18538067:  # Segment
            children = bytearray()
            for child, body in elements(payload):
                if child in (0x114D9B74, 0x1C53BB6B):  # Offset indexes become stale.
                    continue
                if child == 0x1654AE6B:  # Tracks
                    tracks = bytearray()
                    for track, entry in elements(body):
                        if track == 0xAE:
                            fields = list(elements(entry))
                            if any(key == 0x86 and value == b'A_VORBIS' for key, value in fields):
                                entry = b''.join(element(k, v) for k, v in fields if k != 0x56AA)
                                entry += element(0x56AA, nanoseconds.to_bytes(8, 'big'))
                                found += 1
                        tracks += element(track, entry)
                    body = bytes(tracks)
                children += element(child, body)
            payload = bytes(children)
        output += element(identifier, payload)
    if found != 1:
        raise ValueError('expected one owned Vorbis track')
    return output


if __name__ == '__main__':
    source, destination, rate = sys.argv[1:]
    # Round up to retain exactly 1024 samples after the demuxer's conversion.
    Path(destination).write_bytes(with_delay(Path(source).read_bytes(), (1024 * 1_000_000_000 + int(rate) - 1) // int(rate)))
