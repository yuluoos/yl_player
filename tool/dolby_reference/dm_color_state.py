"""Resolve only DM's static color fields in one bounded decode-order epoch.

Pinned libdovi serializes absent compressed fields as zero. These placeholders
must never become effective coefficients. Extension blocks/trim interpretation,
missing DM defaults and cross-ID semantics are deliberately outside this subset.
"""
import json
from stream_inventory import MAX_PACKETS, digest, require

COLOR_RANGES = {
    **{f'ycc_to_rgb_coef{i}': (-32768, 32767) for i in range(9)},
    **{f'ycc_to_rgb_offset{i}': (0, 2**32-1) for i in range(3)},
    **{f'rgb_to_lms_coef{i}': (-32768, 32767) for i in range(9)},
    'signal_eotf': (0, 65535), 'signal_eotf_param0': (0, 65535),
    'signal_eotf_param1': (0, 65535), 'signal_eotf_param2': (0, 2**32-1),
    'signal_bit_depth': (8, 16), 'signal_color_space': (0, 3),
    'signal_chroma_format': (0, 3), 'signal_full_range_flag': (0, 3),
    'source_min_pq': (0, 4095), 'source_max_pq': (0, 4095),
    'source_diagonal': (0, 1023),
}
HEADER_RANGES = {
    'rpu_nal_prefix': (25, 25), 'rpu_type': (2, 2), 'rpu_format': (0, 2047),
    'vdr_rpu_profile': (0, 15), 'vdr_rpu_level': (0, 0),
    'coefficient_data_type': (0, 1), 'coefficient_log2_denom': (0, 23),
    'coefficient_log2_denom_length': (0, 32), 'vdr_rpu_normalized_idc': (0, 3),
    'bl_bit_depth_minus8': (2, 2), 'el_bit_depth_minus8': (2, 2),
    'ext_mapping_idc_0_4': (0, 31), 'ext_mapping_idc_5_7': (0, 7),
    'vdr_bit_depth_minus8': (0, 6), 'reserved_zero_3bits': (0, 1),
    'prev_vdr_rpu_id': (0, 15),
}
HEADER_FLAGS = {
    'vdr_seq_info_present_flag', 'chroma_resampling_explicit_filter_flag',
    'bl_video_full_range_flag', 'spatial_resampling_filter_flag',
    'el_spatial_resampling_filter_flag', 'disable_residual_flag',
    'vdr_dm_metadata_present_flag', 'use_prev_vdr_rpu_flag',
}
DM_CONTROL = {'compressed', 'affected_dm_metadata_id', 'current_dm_metadata_id', 'scene_refresh_flag'}
DM_EXTENSIONS = {'cmv29_metadata', 'cmv40_metadata'}


def encoded(value):
    data = json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
    require(len(data) <= 1024*1024)
    return data


def integer_in(value, lo, hi):
    require(type(value) is int and lo <= value <= hi)


def resolve(values):
    require(isinstance(values, list) and 0 < len(values) <= MAX_PACKETS)
    previous = None
    result = []
    for index, value in enumerate(values):
        require(isinstance(value, dict))
        encoded(value)
        header = value.get('rpu_header')
        require(isinstance(header, dict) and set(header) == set(HEADER_RANGES) | HEADER_FLAGS)
        for key, bounds in HEADER_RANGES.items():
            integer_in(header[key], *bounds)
        for key in HEADER_FLAGS:
            require(type(header[key]) is bool)
        require(header['vdr_seq_info_present_flag'] and header['vdr_dm_metadata_present_flag'])
        require(header['rpu_format'] & 0x700 == 0)
        require(type(value.get('profile')) is int and value['profile'] in (5, 7, 8))
        require(value.get('el_type') in (None, 'MEL', 'FEL'))
        require(type(value.get('unparsed_rpu_bits')) is int and value['unparsed_rpu_bits'] == 0)
        require(type(value.get('use_previous_mapping')) is bool and
                header['use_prev_vdr_rpu_flag'] == value['use_previous_mapping'])
        if header['use_prev_vdr_rpu_flag']:
            integer_in(value.get('previous_mapping_id'), 0, 15)
            require(header['prev_vdr_rpu_id'] == value['previous_mapping_id'])
        else:
            require(header['prev_vdr_rpu_id'] == 0)
        dm = value.get('display_metadata')
        require(isinstance(dm, dict))
        require(set(COLOR_RANGES) | DM_CONTROL <= set(dm) <= set(COLOR_RANGES) | DM_CONTROL | DM_EXTENSIONS)
        compressed = dm['compressed']
        require(type(compressed) is bool and int(compressed) == header['reserved_zero_3bits'])
        if compressed:
            require(value['profile'] == 8)
        identifier = dm['affected_dm_metadata_id']
        integer_in(identifier, 0, 15)
        integer_in(dm['current_dm_metadata_id'], 0, 15)
        require(identifier == dm['current_dm_metadata_id'])
        integer_in(dm['scene_refresh_flag'], 0, 1)
        color = {key: dm[key] for key in COLOR_RANGES}
        for key, bounds in COLOR_RANGES.items():
            integer_in(color[key], *((0, 0) if compressed else bounds))
        # A new complete header may establish a new configuration. Compression
        # may only refer to the immediately established same-ID configuration.
        configuration = {key: val for key, val in header.items() if key not in
                         {'reserved_zero_3bits', 'use_prev_vdr_rpu_flag', 'prev_vdr_rpu_id'}}
        configuration.update(profile=value['profile'], el_type=value['el_type'])
        if compressed:
            require(previous is not None and previous[0] == identifier and previous[1] == configuration)
            color, source = previous[2], previous[3]
        else:
            source = index
            previous = (identifier, configuration, color, source)
        result.append({
            'dm_metadata_id': identifier, 'signalled_compressed': compressed,
            'scene_refresh_flag': dm['scene_refresh_flag'],
            'color_source_packet_index': source, 'color': dict(color),
            'color_sha256': digest(encoded(color)),
            'rpu_header_sha256': digest(encoded(header)),
        })
    return result
