import gzip,hashlib,io,json,os,shutil,subprocess
from pathlib import Path
from test_p8_provenance import P8ProvenanceTests as T
from decoded_alignment import decode
from stream_inventory import file_digest
out=Path('/private/tmp/yl-p07-p8-state')
T.setUpClass()
try:
    test=T('test_real_decode_binds_compressed_state_across_reorder_and_reset');test.test_real_decode_binds_compressed_state_across_reorder_and_reset()
    trace=io.BytesIO();summary=decode(T.media,file_digest(T.media),T.inspector,T.decoder,trace_sink=trace,include_metadata=True)
    (out/'decoded-trace.jsonl.gz').write_bytes(gzip.compress(trace.getvalue(),mtime=0))
    (out/'decoded-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    rows=[json.loads(x) for x in trace.getvalue().splitlines()]
    receipt={'kind':'synthetic_transport_only','frames':len(rows),'reordered':sum(i!=r['packet_index'] for i,r in enumerate(rows)),
        'display_order_packet_indices':[r['packet_index'] for r in rows],
        'inherited_source_later_in_presentation':sum(next(x for x in rows if x['packet_index']==r['dm_color_state']['color_source_packet_index'])['pts']>r['pts'] for r in rows),
        'test':'test_real_decode_binds_compressed_state_across_reorder_and_reset passed',
        'source_rpu_and_modified_pixels_verified':True,'mapping_quality':'external_missing','native_dv_signal':'external_missing',
        'identities':{},'ffmpeg':subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[:3],
        'modules':subprocess.check_output(['pkg-config','--modversion','libavformat','libavcodec','libavutil'],text=True).splitlines()}
    for label,path in [('source',T.source),('synthetic_media',T.media),('raw_rpus',T.root/'valid.rpus'),('mux',T.mux),('decoder',T.decoder),('inspector',T.inspector),('fixture',T.fixture)]:
        receipt['identities'][label]={'sha256':file_digest(path),'bytes':path.stat().st_size}
        shutil.copy2(path,out/('retained-'+label+path.suffix))
    shutil.copy2(T.root/'decoder/build.json',out/'decoder-build.json')
    (out/'synthetic-verification.json').write_text(json.dumps(receipt,indent=2)+'\n')
finally:T.doClassCleanups()
