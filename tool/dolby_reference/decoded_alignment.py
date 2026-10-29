"""Offline decoded BL/EL provenance, never a Dolby target-quality assertion."""
import argparse
import io
import json
import os
from pathlib import Path
import re
import shutil
import struct
import tempfile
from stream_inventory import (MAX_MEDIA, MAX_PACKET, MAX_PACKETS, InspectionError,
                              digest, file_digest, inspect, integer, layer_nal_kind,
                              nal_length_size, require, run_bounded)

START = b'\0\0\0\1'


def split_unit(data, length_size, *, parameters=False):
    require(length_size in (1,2,3,4) and len(data)<=MAX_PACKET)
    layers=[bytearray(),bytearray()]; pictures=[0,0]; offset=0
    while offset<len(data):
        require(offset+length_size<=len(data))
        count=int.from_bytes(data[offset:offset+length_size],'big');offset+=length_size
        require(2<=count<=len(data)-offset)
        nal=data[offset:offset+count];offset+=count
        kind=layer_nal_kind(nal);side=0
        if kind==63:
            nal=nal[2:];kind=layer_nal_kind(nal);side=1
            require(kind not in (62,63))
        if kind==62: continue
        if parameters: require(kind in (32,33,34,39,40))
        if kind<=31: pictures[side]+=int(bool(nal[2]&128))
        layers[side].extend(START+nal)
    if not parameters: require(pictures[0]==1 and pictures[1] in (0,1))
    return bytes(layers[0]),bytes(layers[1])


def parameter_sets(dump):
    # Validate hvcC framing through the existing collector first.
    nal_length_size(dump)
    raw=b''.join(bytes.fromhex(line.partition(': ')[2].split('  ',1)[0])
                 for line in dump.strip().splitlines())
    offset=23;framed=bytearray()
    for _ in range(raw[22]):
        require(offset+3<=len(raw));kind=raw[offset]&63
        count=int.from_bytes(raw[offset+1:offset+3],'big');offset+=3
        for _ in range(count):
            require(offset+2<=len(raw));size=int.from_bytes(raw[offset:offset+2],'big');offset+=2
            require(2<=size<=len(raw)-offset)
            nal=raw[offset:offset+size];offset+=size
            require(layer_nal_kind(nal)==kind)
            framed.extend(size.to_bytes(4,'big')+nal)
    require(offset==len(raw))
    return split_unit(bytes(framed),4,parameters=True)


def pair_frames(rows, base, enhancement):
    require(0<len(rows)<=MAX_PACKETS)
    packets={integer(r['packet_index']):r for r in rows}
    require(set(packets)==set(range(len(rows))) and len({integer(r['pts']) for r in rows})==len(rows))
    def validate(frames):
        require(isinstance(frames,list) and len(frames)==len(rows))
        seen=set();previous=None
        for f in frames:
            index=integer(f['packet_index']);pts=integer(f['pts'])
            require(type(f['poc']) is int and -(2**31)<f['poc']<2**31)
            require(index in packets and index not in seen and pts==packets[index]['pts'])
            require(previous is None or pts>previous);previous=pts;seen.add(index)
            require(type(f['width']) is int and type(f['height']) is int
                    and 0<f['width']<=4096 and 0<f['height']<=2160)
            require(isinstance(f['pixels_sha256'],str) and re.fullmatch('[0-9a-f]{64}',f['pixels_sha256']))
            require(f['pixel_format'] in ('yuv420p','yuv420p10le','yuv420p12le'))
            require(f['picture_type'] in ('I','P','B'))
        return {f['packet_index']:f for f in frames}
    b=validate(base);e=validate(enhancement) if enhancement is not None else None
    if e is not None: require(all(b[i]['poc']==e[i]['poc'] for i in packets))
    return [{**r,'base':b[r['packet_index']],
             'enhancement':e[r['packet_index']] if e is not None else None}
            for r in sorted(rows,key=lambda r:r['pts'])]


def decode(media, expected_sha256, inspector, decoder, ffprobe='ffprobe', *, trace_sink=None, include_metadata=False):
    media=Path(media).resolve(strict=True);decoder=Path(decoder).resolve(strict=True)
    ffprobe=Path(shutil.which(str(ffprobe)) or ffprobe).resolve(strict=True)
    decoder_hash=file_digest(decoder);ffprobe_hash=file_digest(ffprobe)
    inventory_trace=io.BytesIO()
    inventory=inspect(media,expected_sha256,inspector,str(ffprobe),trace_sink=inventory_trace,include_layers=True,include_dm_blocks=include_metadata)
    rows=[json.loads(line) for line in inventory_trace.getvalue().splitlines()]
    require(set(inventory['profile_counts']) in ({'5'},{'7'}))
    has_el=set(inventory['profile_counts'])=={'7'}
    require(not has_el or inventory['layer_inventory']['packets_with_enhancement_vcl']==len(rows))
    require(has_el or inventory['layer_inventory']['enhancement_nals']==0)
    probe=json.loads(run_bounded([str(ffprobe),'-v','error','-protocol_whitelist','file',
        '-f','mov','-use_absolute_path','0','-select_streams','v','-show_streams','-show_packets',
        '-show_data','-show_entries','stream=extradata:packet=pts,dts,pos,size','-of','json',str(media)]))
    require(len(probe['streams'])==1 and len(probe['packets'])==len(rows))
    extra=probe['streams'][0]['extradata'];length=nal_length_size(extra)
    headers=parameter_sets(extra)
    by_index={r['packet_index']:r for r in rows}
    with tempfile.TemporaryDirectory(prefix='yl-decoded-layers-') as directory:
        paths=[Path(directory)/name for name in ('base.bin','enhancement.bin')]
        with media.open('rb') as source,paths[0].open('wb') as bl,paths[1].open('wb') as el:
            for i,p in enumerate(probe['packets']):
                pts,dts,pos,size=(integer(p[k]) for k in ('pts','dts','pos','size'))
                require(pts==by_index[i]['pts'] and dts==by_index[i]['dts'] and 0<size<=MAX_PACKET)
                require(0<=pos and pos+size<=media.stat().st_size)
                source.seek(pos);data=source.read(size);require(len(data)==size)
                layers=split_unit(data,length)
                require(bool(layers[1])==has_el)
                for side,output in enumerate((bl,el)):
                    if side and not has_el: continue
                    payload=(headers[side] if i==0 else b'')+layers[side]
                    require(0<len(payload)<=MAX_PACKET)
                    output.write(struct.pack('>qqII',pts,dts,i,len(payload)));output.write(payload)
                    require(output.tell()<=MAX_MEDIA)
        decoded=[]
        for path in paths[:2 if has_el else 1]:
            raw=run_bounded([str(decoder),str(path)],limit=32*1024*1024,timeout=600)
            decoded.append([json.loads(line) for line in raw.splitlines()])
    require(file_digest(media)==expected_sha256 and file_digest(decoder)==decoder_hash
            and file_digest(ffprobe)==ffprobe_hash)
    pairs=pair_frames(rows,decoded[0],decoded[1] if has_el else None)
    trace=b''.join((json.dumps(r,sort_keys=True,separators=(',',':'))+'\n').encode() for r in pairs)
    if trace_sink is not None: trace_sink.write(trace)
    result = dict(schema_version=1,inspection='decoded_packet_provenance',media_sha256=expected_sha256,
        decoder_sha256=decoder_hash,ffprobe_sha256=ffprobe_hash,inspector_sha256=inventory['inspector_sha256'],
        time_base=inventory['time_base'],decoded_frames=len(pairs),enhancement_decoded=has_el,
        packet_to_decoded_frame_verified=True,decoded_layer_pairing_verified=has_el,
        decoder_identity='software_hevc_copy_opaque_packet_index_original_pts_and_parser_poc',
        standalone_poc_verified=True,effective_metadata_resolved=False,
        previous_mapping_rpus=inventory['previous_mapping_rpus'],trace_sha256=digest(trace),
        mapping_quality='external_missing',native_dv_signal='external_missing')
    if include_metadata:
        result.update(schema_version=2, mapping_reference_ids_resolved=True,
            dm_color_state_resolved=True, dm_block_state_resolved=True,
            metadata_scope='mapping_reference_color_and_known_block_transport_only',
            metadata_inventory_trace_sha256=inventory['presentation_trace_sha256'],
            compressed_dm_color_rpus=inventory['compressed_dm_color_rpus'],
            inherited_static_block_instances=inventory['inherited_static_block_instances'])
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('media','sha256','inspector','decoder'):p.add_argument('--'+name,required=True)
    p.add_argument('--ffprobe',default='ffprobe');p.add_argument('--trace',type=Path)
    p.add_argument('--metadata',action='store_true',help='Bind mapping, color and known CM block provenance to decoded frames; not pixel qualification.')
    a=p.parse_args()
    try:
        trace=io.BytesIO();result=decode(a.media,a.sha256,a.inspector,a.decoder,a.ffprobe,trace_sink=trace,include_metadata=a.metadata)
        if a.trace is not None:
            with a.trace.open('xb') as output: output.write(trace.getvalue())
        print(json.dumps(result,sort_keys=True,indent=2));return 0
    except (InspectionError,OSError,ValueError,KeyError,TypeError,RuntimeError):
        print('{"code":"dolby.decoded_alignment_failed","mapping_quality":"external_missing"}');return 2

if __name__=='__main__':raise SystemExit(main())
