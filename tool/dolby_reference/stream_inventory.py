"""Offline, bounded inventory of signalled RPU metadata in one HEVC MP4 track.

Optional mapping/color modes resolve only their explicit subsets. No picture
decoding, full effective DM/trim resolution or DV mapping certification.
"""
import argparse
from collections import Counter
import hashlib
import io
import os
import json
from pathlib import Path
import re
import selectors
import subprocess
import tempfile
import time

MAX_MEDIA = 512 * 1024 * 1024
MAX_PACKET = 8 * 1024 * 1024
MAX_PACKETS = 32768
MAX_RPU = 65536
MAX_FRAMED = 32 * 1024 * 1024


class InspectionError(ValueError):
    def __init__(self):
        super().__init__('dolby.stream_inspection_failed')


def require(value):
    if not value:
        raise InspectionError()


def integer(value):
    require(type(value) is int or (isinstance(value, str) and re.fullmatch(r'-?[0-9]{1,20}', value)))
    value = int(value)
    require(-(2**63) <= value < 2**63)
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path, *, limit=MAX_MEDIA):
    total, value = 0, hashlib.sha256()
    with Path(path).open('rb') as source:
        while chunk := source.read(65536):
            total += len(chunk)
            require(total <= limit)
            value.update(chunk)
    return value.hexdigest()


def run_bounded(command, *, limit=16*1024*1024, timeout=60):
    """POSIX host tool runner: bounded stdout, deadline, no raw stderr disclosure."""
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    result = bytearray()
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                require(remaining > 0)
                require(selector.select(remaining))
                data = process.stdout.read1(65536)
                if not data:
                    break
                result.extend(data)
                require(len(result) <= limit)
        require(process.wait(timeout=max(.001, deadline-time.monotonic())) == 0)
        return bytes(result)
    except (OSError, subprocess.TimeoutExpired):
        raise InspectionError() from None
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


def nal_length_size(dump):
    """Read hvcC lengthSizeMinusOne; do not assume all MP4 uses four bytes."""
    require(isinstance(dump, str) and len(dump) <= 256*1024)
    raw = bytearray()
    for line in dump.strip().splitlines():
        offset, separator, payload = line.partition(': ')
        require(separator and re.fullmatch('[0-9a-fA-F]{8}', offset))
        require(int(offset, 16) == len(raw))
        hex_part = payload.split('  ', 1)[0]
        require(re.fullmatch('[0-9a-fA-F ]+', hex_part))
        try:
            raw.extend(bytes.fromhex(hex_part))
        except ValueError:
            raise InspectionError() from None
    require(len(raw) >= 23 and raw[0] == 1)
    return (raw[21] & 3) + 1


def mp4_media_ranges(source, media_size):
    """Check finite top-level box extents before trusting demuxed coverage.

    This collector deliberately refuses fragmented or open-ended containers.
    Stream nb_frames is checked separately against the returned packet count.
    """
    offset, boxes, moov, ranges = 0, 0, 0, []
    while offset < media_size:
        source.seek(offset)
        header = source.read(8)
        require(len(header) == 8)
        size, kind = int.from_bytes(header[:4], 'big'), header[4:]
        header_size = 8
        if size == 1:
            extended = source.read(8)
            require(len(extended) == 8)
            size, header_size = int.from_bytes(extended, 'big'), 16
        require(header_size <= size <= media_size-offset and kind != b'moof')
        moov += int(kind == b'moov')
        if kind == b'mdat':
            ranges.append((offset+header_size, offset+size))
        offset += size
        boxes += 1
        require(boxes <= MAX_PACKETS)
    require(moov == 1 and ranges)
    return ranges


def layer_nal_kind(nal):
    """This inventory supports layer-zero HEVC and UNSPEC63 EL wrapping only."""
    require(len(nal) >= 2 and not (nal[0] & 128) and (nal[1] & 7) != 0)
    require(((nal[0] & 1) << 5 | nal[1] >> 3) == 0)
    kind = (nal[0] >> 1) & 63
    # A VCL header alone cannot contain even first_slice_segment_in_pic_flag.
    require(kind > 31 or len(nal) > 2)
    return kind


def extract_rpus(source, packets, *, length_size, stream_index, media_size,
                 include_layers=False):
    require(length_size in (1, 2, 3, 4) and 0 < media_size <= MAX_MEDIA)
    require(isinstance(packets, list) and 0 < len(packets) <= MAX_PACKETS)
    rows, framed, seen_pts, ranges = [], bytearray(), set(), []
    last_dts = None
    for index, packet in enumerate(packets):
        require(integer(packet['stream_index']) == stream_index)
        pts, dts = integer(packet['pts']), integer(packet['dts'])
        pos, size = integer(packet['pos']), integer(packet['size'])
        require(0 <= pos and 0 < size <= MAX_PACKET and pos + size <= media_size)
        require(pts not in seen_pts and (last_dts is None or dts > last_dts))
        seen_pts.add(pts); last_dts = dts; ranges.append((pos, pos+size))
        source.seek(pos); data = source.read(size)
        require(len(data) == size)
        offset, rpus, vcl = 0, [], 0
        el_nals, el_vcl, el_hash = 0, 0, hashlib.sha256()
        while offset < size:
            require(offset + length_size <= size)
            length = int.from_bytes(data[offset:offset+length_size], 'big')
            offset += length_size
            require(2 <= length and offset + length <= size)
            nal = data[offset:offset+length]; offset += length
            require(not (nal[0] & 128) and (nal[1] & 7) != 0)
            kind = (nal[0] >> 1) & 63
            vcl += int(kind <= 31)
            if include_layers:
                layer_nal_kind(nal)
                if kind == 63:
                    inner_kind = layer_nal_kind(nal[2:])
                    require(inner_kind not in (62, 63))
                    el_nals += 1
                    el_vcl += int(inner_kind <= 31)
                    # Hash original wrapper bytes with canonical u32 lengths,
                    # independent of the MP4's lengthSizeMinusOne setting.
                    el_hash.update(len(nal).to_bytes(4, 'big'))
                    el_hash.update(nal)
            if kind == 62:
                require(length <= MAX_RPU)
                rpus.append(nal)
        # This first collector deliberately rejects partial/ambiguous coverage.
        # It does not guess associations for multi-RPU or non-picture packets.
        require(vcl > 0 and len(rpus) == 1)
        rpu = rpus[0]
        require(len(framed) + 4 + len(rpu) <= MAX_FRAMED)
        framed.extend(len(rpu).to_bytes(4, 'big')); framed.extend(rpu)
        rows.append({'packet_index': index, 'pts': pts, 'dts': dts,
                     'rpu_sha256': digest(rpu)})
        if include_layers:
            rows[-1]['nal_inventory'] = {
                'base_vcl_nals': vcl, 'enhancement_vcl_nals': el_vcl,
                'enhancement_nals': el_nals,
                'enhancement_sha256': el_hash.hexdigest() if el_nals else None}

    ranges.sort()
    require(all(a[1] <= b[0] for a, b in zip(ranges, ranges[1:])))
    return rows, bytes(framed)


def summarize(rows, parsed, *, time_base, media_sha256, trace_sink=None, include_layers=False, include_mapping=False, include_dm_color=False, include_dm_blocks=False):
    require(0 < len(rows) == len(parsed) <= MAX_PACKETS)
    require(isinstance(time_base, str) and re.fullmatch('[1-9][0-9]*/[1-9][0-9]*', time_base))
    require(re.fullmatch('[0-9a-f]{64}', media_sha256))
    levels, cms, profiles, el_types = Counter(), Counter(), Counter(), Counter()
    previous, absent, cuts, unparsed = 0, 0, 0, 0
    records = []
    mapping_references = None
    dm_color_states = None
    dm_block_states = None
    include_dm_color = include_dm_color or include_dm_blocks
    include_mapping = include_mapping or include_dm_color
    if include_mapping:
        require(all(type(row.get('packet_index')) is int and row['packet_index'] == index
                    for index, row in enumerate(rows)))
        from mapping_references import resolve
        mapping_references = resolve(parsed)
    if include_dm_color:
        from dm_color_state import resolve as resolve_color
        dm_color_states = resolve_color(parsed)
    if include_dm_blocks:
        from dm_block_state import resolve as resolve_blocks
        dm_block_states = resolve_blocks(parsed)
    for row, value in zip(rows, parsed):
        require(set(value) == {'profile','el_type','cm_levels','display_metadata','use_previous_mapping','unparsed_rpu_bits'} | ({'mapping','previous_mapping_id'} if include_mapping else set()) | ({'rpu_header'} if include_dm_color else set()))
        profile = integer(value['profile']); require(0 <= profile <= 255)
        require(value['el_type'] in (None, 'MEL', 'FEL'))
        require(type(value['use_previous_mapping']) is bool)
        require(isinstance(value['cm_levels'], dict))
        current_levels = set()
        for cm, block_levels in value['cm_levels'].items():
            require(cm in ('2.9', '4.0') and isinstance(block_levels, list))
            require(all(type(level) is int and 0 <= level <= 255 for level in block_levels))
            cms[cm] += 1; current_levels.update(block_levels)
        levels.update(str(level) for level in current_levels)
        profiles[str(profile)] += 1
        el_types[value['el_type'] or 'none'] += 1
        previous += int(value['use_previous_mapping'])
        remaining = integer(value['unparsed_rpu_bits']); require(0 <= remaining <= MAX_RPU*8)
        unparsed += int(remaining != 0)
        dm = value['display_metadata']
        require(dm is None or isinstance(dm, dict))
        absent += int(dm is None)
        if dm is not None:
            require(dm.get('scene_refresh_flag') in (0, 1))
            cuts += int(dm['scene_refresh_flag'] == 1)
        fingerprint = digest(json.dumps(dm, sort_keys=True, separators=(',', ':'), allow_nan=False).encode())
        records.append({**row, 'display_metadata_sha256': fingerprint,
                        'profile':profile, 'levels':sorted(current_levels),
                        'cm':sorted(value['cm_levels']),
                        'use_previous_mapping':value['use_previous_mapping']})
        if mapping_references is not None:
            records[-1]['mapping_reference'] = mapping_references[len(records)-1]
        if dm_color_states is not None:
            records[-1]['dm_color_state'] = dm_color_states[len(records)-1]
            records[-1]['rpu_header'] = value['rpu_header']
        if dm_block_states is not None:
            records[-1]['dm_block_state'] = dm_block_states[len(records)-1]
    presentation = sorted(records, key=lambda row: row['pts'])
    require(len({row['pts'] for row in records}) == len(records))
    transitions = sum(a['display_metadata_sha256'] != b['display_metadata_sha256']
                      for a,b in zip(presentation, presentation[1:]))
    trace = b''.join((json.dumps(row, sort_keys=True, separators=(',', ':'))+'\n').encode()
                     for row in presentation)
    if trace_sink is not None:
        trace_sink.write(trace)
    result = {'schema_version':1, 'inspection':'signalled_rpu_inventory',
            'media_sha256':media_sha256, 'rpu_count':len(rows),
            'profile_counts':dict(profiles), 'el_type_counts':dict(el_types),
            'cm_counts':dict(sorted(cms.items())),
            'level_counts':dict(sorted(levels.items(), key=lambda row:int(row[0]))),
            'previous_mapping_rpus':previous, 'rpus_with_unparsed_bits':unparsed, 'absent_display_metadata_rpus':absent,
            'scene_refresh_flag_count':cuts, 'display_metadata_transitions':transitions,
            'unique_rpu_hashes':len({row['rpu_sha256'] for row in rows}),
            'time_base':time_base, 'pts_range':[presentation[0]['pts'],presentation[-1]['pts']],
            'presentation_reordered_packets':sum(row['packet_index'] != i for i,row in enumerate(presentation)),
            'presentation_trace_sha256':digest(trace),
            'first_packet_rpu_sha256':rows[0]['rpu_sha256'],
            'effective_metadata_resolved':False, 'decoded_frame_alignment_verified':False,
            'mapping_quality':'external_missing', 'native_dv_signal':'external_missing'}
    if include_layers:
        result['schema_version'] = 2
        inventories = [row['nal_inventory'] for row in rows]
        result['layer_inventory'] = {
            'encoding': 'single_track_unspec63_wrapped_el',
            'base_vcl_nals': sum(row['base_vcl_nals'] for row in inventories),
            'enhancement_vcl_nals': sum(row['enhancement_vcl_nals'] for row in inventories),
            'enhancement_nals': sum(row['enhancement_nals'] for row in inventories),
            'packets_with_enhancement_vcl': sum(row['enhancement_vcl_nals'] > 0 for row in inventories),
            'p7_packets_without_enhancement_vcl': sum(
                value['profile'] == 7 and row['enhancement_vcl_nals'] == 0
                for value, row in zip(parsed, inventories)),
            'decoded_layer_pairing_verified': False}
    if include_mapping:
        result['schema_version'] = 3
        result['mapping_reference_ids_resolved'] = True
    if include_dm_color:
        result['schema_version'] = 4
        result['dm_color_state_resolved'] = True
        result['compressed_dm_color_rpus'] = sum(row['signalled_compressed'] for row in dm_color_states)
        result['dm_color_scope'] = 'static_color_fields_same_id_same_configuration'
    if include_dm_blocks:
        result['schema_version'] = 5
        result['dm_block_state_resolved'] = True
        result['dm_block_scope'] = 'known_static_inheritance_and_current_packet_dynamic_blocks'
        result['inherited_static_block_instances'] = sum(row['inherited_static_blocks'] for row in dm_block_states)
    return result


def inspect(media, expected_sha256, inspector, ffprobe='ffprobe', *, trace_sink=None, include_layers=False, include_mapping=False, include_dm_color=False, include_dm_blocks=False):
    include_dm_color = include_dm_color or include_dm_blocks
    include_mapping = include_mapping or include_dm_color
    media = Path(media).resolve(strict=True)
    inspector = Path(inspector).resolve(strict=True)
    inspector_sha256 = file_digest(inspector)
    require(media.is_file() and 0 < media.stat().st_size <= MAX_MEDIA)
    require(re.fullmatch('[0-9a-f]{64}', expected_sha256))
    require(file_digest(media) == expected_sha256)
    with media.open('rb') as source:
        media_ranges = mp4_media_ranges(source, media.stat().st_size)
    # Only local MP4 demux; no decode, remux, bitstream filter or device access.
    probe = json.loads(run_bounded([ffprobe, '-v','error','-protocol_whitelist','file',
        '-f','mov','-use_absolute_path','0','-select_streams','v',
        '-show_streams','-show_packets','-show_data','-show_entries',
        'stream=index,codec_name,codec_type,time_base,extradata,nb_frames:packet=stream_index,pts,dts,pos,size',
        '-of','json',str(media)]))
    require(len(probe['streams']) == 1)
    stream = probe['streams'][0]
    require(stream['codec_name'] == 'hevc' and stream['codec_type'] == 'video')
    declared_samples = integer(stream.get('nb_frames'))
    require(isinstance(probe['packets'], list))
    require(0 < declared_samples == len(probe['packets']) <= MAX_PACKETS)
    for packet in probe['packets']:
        pos, size = integer(packet['pos']), integer(packet['size'])
        require(size > 0 and any(start <= pos and pos+size <= end
                                for start, end in media_ranges))
    with media.open('rb') as source:
        rows, framed = extract_rpus(source, probe['packets'],
            length_size=nal_length_size(stream['extradata']),
            stream_index=integer(stream['index']), media_size=media.stat().st_size,
            include_layers=include_layers)
    with tempfile.TemporaryDirectory(prefix='yl-dovi-rpus-') as scratch:
        path = Path(scratch)/'rpus.bin'; path.write_bytes(framed)
        parsed = [json.loads(line) for line in run_bounded([str(Path(inspector).resolve(strict=True)),str(path)] + (['--dm-color'] if include_dm_color else ['--mapping'] if include_mapping else []),
                  limit=128*1024*1024).splitlines()]
    require(file_digest(media) == expected_sha256)
    require(file_digest(inspector) == inspector_sha256)
    result = summarize(rows, parsed, time_base=stream['time_base'], media_sha256=expected_sha256, trace_sink=trace_sink,
                       include_layers=include_layers, include_mapping=include_mapping, include_dm_color=include_dm_color, include_dm_blocks=include_dm_blocks)
    result['inspector_sha256'] = inspector_sha256
    result['packet_count'] = len(probe['packets'])
    result['declared_sample_count'] = declared_samples
    result['container_coverage'] = 'finite_box_extents_and_declared_samples'
    result['nal_length_size'] = nal_length_size(stream['extradata'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--media',required=True)
    parser.add_argument('--sha256',required=True)
    parser.add_argument('--inspector',required=True)
    parser.add_argument('--ffprobe',default='ffprobe')
    parser.add_argument('--layers', action='store_true', help='Include schema 2 BL/EL NAL coverage; not decoded pairing.')
    parser.add_argument('--mapping', action='store_true', help='Resolve mapping ID provenance in decode order; not effective DM/trim state.')
    parser.add_argument('--dm-color', action='store_true', help='Resolve the bounded static DM color subset; implies --mapping. Not CM/trim mapping.')
    parser.add_argument('--dm-blocks', action='store_true', help='Resolve known static CM block inheritance and per-packet dynamic blocks; implies --dm-color. Does not execute trims.')
    parser.add_argument('--trace',type=Path,help='Optional new JSONL trace file; existing paths are refused.')
    args = parser.parse_args()
    try:
        trace = io.BytesIO()
        result = inspect(args.media,args.sha256,args.inspector,args.ffprobe,trace_sink=trace,include_layers=args.layers,include_mapping=args.mapping,include_dm_color=args.dm_color,include_dm_blocks=args.dm_blocks)
        if args.trace is not None:
            fd = os.open(args.trace,os.O_WRONLY | os.O_CREAT | os.O_EXCL,0o600)
            try:
                with os.fdopen(fd,'wb') as output:
                    output.write(trace.getvalue())
            except BaseException:
                args.trace.unlink(missing_ok=True)
                raise
        print(json.dumps(result,sort_keys=True,indent=2))
        return 0
    except (InspectionError, OSError, ValueError, KeyError, TypeError):
        print('{"code":"dolby.stream_inspection_failed","mapping_quality":"external_missing","native_dv_signal":"external_missing"}')
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
