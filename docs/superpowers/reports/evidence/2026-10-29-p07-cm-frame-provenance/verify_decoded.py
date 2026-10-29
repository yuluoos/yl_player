from pathlib import Path
import hashlib,json,sys
root=Path(sys.argv[1]); results=[]
def sha(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()).hexdigest()
for name,count,enhancement in [('fel',2908,True),('p5',6314,False)]:
    report=json.loads((root/(name+'-decoded.json')).read_text())
    raw=(root/(name+'-decoded.jsonl')).read_bytes()
    rows=[json.loads(line) for line in raw.splitlines()];by_index={r['packet_index']:r for r in rows}
    assert len(rows)==len(by_index)==report['decoded_frames']==count
    assert set(by_index)==set(range(count))
    assert hashlib.sha256(raw).hexdigest()==report['trace_sha256']
    assert report['schema_version']==2 and report['dm_block_state_resolved']
    assert report['compressed_dm_color_rpus']==report['inherited_static_block_instances']==0
    assert not report['effective_metadata_resolved']
    assert report['enhancement_decoded']==report['decoded_layer_pairing_verified']==enhancement
    assert all(a['pts']<b['pts'] for a,b in zip(rows,rows[1:]))
    for row in rows:
        color=row['dm_color_state'];blocks=row['dm_block_state'];mapping=row['mapping_reference']
        assert sha(row['rpu_header'])==color['rpu_header_sha256']
        assert sha(color['color'])==color['color_sha256']
        assert 0<=color['color_source_packet_index']<=row['packet_index']
        assert by_index[color['color_source_packet_index']]['dm_color_state']['color_sha256']==color['color_sha256']
        assert 0<=mapping['mapping_source_packet_index']<=row['packet_index']
        assert by_index[mapping['mapping_source_packet_index']]['mapping_reference']['mapping_sha256']==mapping['mapping_sha256']
        content=[]
        for block in blocks['blocks']:
            assert sha(block['payload'])==block['payload_sha256']
            source=block['source_packet_index'];assert 0<=source<=row['packet_index']
            candidates=by_index[source]['dm_block_state']['blocks']
            assert sum((b['cm'],b['level'],b['target'],b['payload_sha256'])==(block['cm'],block['level'],block['target'],block['payload_sha256']) for b in candidates)==1
            content.append({k:block[k] for k in ('cm','level','target','payload')})
        assert sha(content)==blocks['blocks_sha256']
        assert row['base']['packet_index']==row['packet_index'] and row['base']['pts']==row['pts']
        if enhancement:
            assert row['enhancement']['packet_index']==row['packet_index'] and row['enhancement']['pts']==row['pts']
            assert row['enhancement']['poc']==row['base']['poc']
        else:assert row['enhancement'] is None
    results.append(dict(name=name,frames=count,enhancement=enhancement,all_metadata_hashes_and_sources_verified=True,presentation_reordered_packets=sum(i!=r['packet_index'] for i,r in enumerate(rows))))
(root/'decoded-verification.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
