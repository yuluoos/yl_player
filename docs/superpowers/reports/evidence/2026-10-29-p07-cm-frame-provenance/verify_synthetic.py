import hashlib,io,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'tool/dolby_reference'))
from stream_inventory import summarize
root=Path(sys.argv[2]);raw=(root/'synthetic.rpus').read_bytes()
parsed=[json.loads(line) for line in (root/'synthetic-parsed.jsonl').read_bytes().splitlines()]
rows=[];offset=0
for index,pts in enumerate([0,3,1,2]):
    size=int.from_bytes(raw[offset:offset+4],'big');offset+=4
    nal=raw[offset:offset+size];offset+=size
    assert len(nal)==size
    rows.append(dict(packet_index=index,pts=pts,dts=index-2,rpu_sha256=hashlib.sha256(nal).hexdigest()))
assert offset==len(raw) and len(parsed)==4
trace=io.BytesIO();report=summarize(rows,parsed,time_base='1/24',media_sha256=hashlib.sha256(raw).hexdigest(),include_dm_blocks=True,trace_sink=trace)
records=[json.loads(line) for line in trace.getvalue().splitlines()];by_index={r['packet_index']:r for r in records}
assert [r['packet_index'] for r in records]==[0,2,3,1]
assert report['compressed_dm_color_rpus']==2 and report['inherited_static_block_instances']==2
assert [by_index[i]['dm_color_state']['color_source_packet_index'] for i in range(4)]==[0,0,2,2]
assert [by_index[i]['mapping_reference']['mapping_source_packet_index'] for i in range(4)]==[0,0,2,2]
assert {b['level'] for b in by_index[1]['dm_block_state']['blocks']}=={1,5,6,254}
assert {b['level'] for b in by_index[3]['dm_block_state']['blocks']}=={1,5}
assert not report['effective_metadata_resolved']
(root/'synthetic-state.jsonl').write_bytes(trace.getvalue())
report.update(test='synthetic_valid_rpu_parser_and_state_contract',real_compressed_video=False)
(root/'synthetic-verification.json').write_text(json.dumps(report,indent=2)+'\n')
print('Synthetic real-parser/state contract passed: 4 RPUs, 2 compressed, 2 inherited static blocks.')
