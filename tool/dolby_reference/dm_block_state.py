"""Bounded CM block transport state; never executes trims or target mapping.

Static classification follows FFmpeg n8.0.1 dovi_rpu.h. Reserved level 32 and
unknown levels are refused. Each call starts with no inheritance history.
"""
import copy
from collections import Counter
from dm_color_state import encoded, integer_in, resolve as resolve_colors
from stream_inventory import digest, require

STATIC_LEVELS = {6, 10, 254, 255}
CM_LEVELS = {'2.9': {1, 2, 4, 5, 6, 255}, '4.0': {3, 8, 9, 10, 11, 254}}
MAX_COUNTS = {2: 8, 8: 5, 10: 4}
TRIM_FIELDS = ('trim_slope', 'trim_offset', 'trim_power', 'trim_chroma_weight', 'trim_saturation_gain')


def ranges(names, maximum, minimum=0):
    return {name: (minimum, maximum) for name in names}


def payload_schema(level, payload):
    schemas = {
        1: ranges(('min_pq', 'max_pq', 'avg_pq'), 4095),
        2: {**ranges(('target_max_pq', *TRIM_FIELDS), 4095), 'ms_weight': (-1, 4095)},
        3: ranges(('min_pq_offset', 'max_pq_offset', 'avg_pq_offset'), 4095),
        4: ranges(('anchor_pq', 'anchor_power'), 4095),
        5: ranges((f'active_area_{side}_offset' for side in ('left', 'right', 'top', 'bottom')), 8191),
        6: ranges(('max_display_mastering_luminance', 'min_display_mastering_luminance',
                   'max_content_light_level', 'max_frame_average_light_level'), 10000),
        11: {**ranges(('content_type', 'whitepoint'), 15), 'reference_mode_flag': None,
             'reserved_byte2': (0, 255), 'reserved_byte3': (0, 0)},
        254: ranges(('dm_mode', 'dm_version_index'), 255),
        255: ranges(('dm_run_mode', 'dm_run_version', *(f'dm_debug{i}' for i in range(4))), 255),
    }
    if level in schemas:
        return schemas[level]
    length = payload.get('length')
    require(type(length) is int)
    if level == 8:
        require(length in (10, 12, 13, 19, 25))
        schema = {'length': (length, length), 'target_display_index': (0, 255),
                  **ranges((*TRIM_FIELDS, 'ms_weight'), 4095)}
        if length >= 12: schema['target_mid_contrast'] = (0, 4095)
        if length >= 13: schema['clip_trim'] = (0, 4095)
        if length >= 19: schema.update(ranges((f'saturation_vector_field{i}' for i in range(6)), 255))
        if length >= 25: schema.update(ranges((f'hue_vector_field{i}' for i in range(6)), 255))
        return schema
    require(level in (9, 10))
    prefix, short, long = ('source', 1, 17) if level == 9 else ('target', 5, 21)
    require(length in (short, long))
    schema = {'length': (length, length), f'{prefix}_primary_index': (0, 255)}
    if level == 10:
        schema.update(target_display_index=(0, 255), target_max_pq=(0, 4095), target_min_pq=(0, 4095))
    if length == long:
        schema.update(ranges((f'{prefix}_primary_{color}_{axis}' for color in ('red', 'green', 'blue', 'white')
                              for axis in ('x', 'y')), 65535))
    return schema


def signalled_blocks(value, index):
    blocks = []
    require(isinstance(value['cm_levels'], dict) and set(value['cm_levels']) <= set(CM_LEVELS))
    for levels in value['cm_levels'].values():
        require(isinstance(levels, list) and all(type(level) is int for level in levels))
    observed_levels = {}
    for cm, field in [('2.9', 'cmv29_metadata'), ('4.0', 'cmv40_metadata')]:
        container = value['display_metadata'].get(field)
        if container is None:
            continue
        require(isinstance(container, dict) and set(container) == {'num_ext_blocks', 'ext_metadata_blocks'})
        entries = container['ext_metadata_blocks']
        require(isinstance(entries, list))
        integer_in(container['num_ext_blocks'], 0, 16)
        require(container['num_ext_blocks'] == len(entries))
        counts = Counter(); seen = set()
        for entry in entries:
            require(isinstance(entry, dict) and len(entry) == 1)
            label, payload = next(iter(entry.items()))
            allowed = {f'Level{level}': level for level in CM_LEVELS[cm]}
            require(label in allowed and isinstance(payload, dict))
            level = allowed[label]; schema = payload_schema(level, payload)
            require(set(payload) == set(schema))
            for key, bounds in schema.items():
                if bounds is None: require(type(payload[key]) is bool)
                else: integer_in(payload[key], *bounds)
            counts[level] += 1
            require(counts[level] <= MAX_COUNTS.get(level, 1))
            target = payload['target_max_pq'] if level == 2 else payload['target_display_index'] if level in (8, 10) else None
            identity = (level, target)
            require(identity not in seen); seen.add(identity)
            blocks.append(dict(cm=cm, level=level, target=target, static=level in STATIC_LEVELS,
                               source_packet_index=index, payload=copy.deepcopy(payload),
                               payload_sha256=digest(encoded(payload))))
        observed_levels[cm] = sorted(counts)
        # Full CM4 declares its static version; compressed CM4 inherits it.
        if cm == '4.0': require(counts[254] == (0 if value['display_metadata']['compressed'] else 1))
    require(value['cm_levels'] == observed_levels)
    return blocks


def resolve(values):
    # Reuse the color contract for same-ID/configuration history, strict header
    # fields, compressed placeholders, finite input and unsupported-mode refusal.
    colors = resolve_colors(values)
    static = []
    result = []
    for index, (value, color) in enumerate(zip(values, colors)):
        current = signalled_blocks(value, index)
        compressed = color['signalled_compressed']
        if compressed:
            require(not any(block['static'] for block in current))
            if value['display_metadata'].get('cmv40_metadata') is not None:
                require(any(block['level'] == 254 for block in static))
        else:
            static = [block for block in current if block['static']]
        active = sorted(static + [block for block in current if not block['static']],
                        key=lambda block: (block['cm'], block['level'], -1 if block['target'] is None else block['target']))
        content = [{key: block[key] for key in ('cm', 'level', 'target', 'payload')} for block in active]
        result.append(dict(blocks=copy.deepcopy(active), blocks_sha256=digest(encoded(content)),
                           inherited_static_blocks=len(static) if compressed else 0))
    return result
