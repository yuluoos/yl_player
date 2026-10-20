"""Resolve signalled RPU mapping IDs in decode order, within one fresh epoch.

This identifies the referenced coefficient record, not effective DM/trim state.
"""
import json
from stream_inventory import MAX_PACKETS, digest, require


def resolve(values):
    require(isinstance(values,list) and 0<len(values)<=MAX_PACKETS)
    mappings={};result=[]
    for index,value in enumerate(values):
        previous=value['use_previous_mapping'];mapping=value['mapping']
        require(type(previous) is bool)
        if previous:
            identifier=value['previous_mapping_id']
            require(mapping is None)
        else:
            require(isinstance(mapping,dict) and value['previous_mapping_id'] is None)
            identifier=mapping.get('vdr_rpu_id')
        require(type(identifier) is int and 0<=identifier<=15)
        if not previous:
            encoded=json.dumps(mapping,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
            require(len(encoded)<=1024*1024)
            mappings[identifier]=dict(mapping_id=identifier,mapping_source_packet_index=index,
                                     mapping_sha256=digest(encoded))
        require(identifier in mappings)
        result.append(dict(mappings[identifier]))
    return result
