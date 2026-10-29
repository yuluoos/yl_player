from pathlib import Path
import gzip,io,json,os,shutil,subprocess
from test_compressed_cm4 import CompressedCm4Tests as T
from decoded_alignment import decode
from stream_inventory import file_digest
out=Path('/private/tmp/yl-p07-cm4');T.setUpClass()
try:
 test=T('test_real_decode_binds_compressed_state_across_reorder_and_reset');test.test_real_decode_binds_compressed_state_across_reorder_and_reset();test.test_unmodified_parser_refuses_raw_compressed_cm4()
 trace=io.BytesIO();summary=decode(T.media,file_digest(T.media),T.inspector,T.decoder,trace_sink=trace,include_metadata=True)
 (out/'decoded-trace.jsonl.gz').write_bytes(gzip.compress(trace.getvalue(),mtime=0));(out/'decoded-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 oracle=subprocess.check_output([str(T.oracle),str(T.media)],timeout=30);(out/'independent-ffmpeg.jsonl.gz').write_bytes(gzip.compress(oracle,mtime=0))
 receipt={'kind':'synthetic_compressed_cm4_transport_only','frames':12,'compressed':6,'inherited_static_instances':summary['inherited_static_block_instances'],'all_transmitted_fields_match_independent_ffmpeg':True,'upstream_refuses_same_rpus':True,'identities':{},'modules':subprocess.check_output(['pkg-config','--modversion','libavformat','libavcodec','libavutil'],text=True).splitlines()}
 for label,path in [('source',T.source),('synthetic_media',T.media),('raw_rpus',T.root/'valid.rpus'),('mux',T.mux),('decoder',T.decoder),('oracle',T.oracle),('inspector',T.inspector),('fixture',T.fixture)]:
  receipt['identities'][label]={'sha256':file_digest(path),'bytes':path.stat().st_size};shutil.copy2(path,out/('retained-'+label+path.suffix))
 (out/'synthetic-verification.json').write_text(json.dumps(receipt,indent=2)+'\n')
 (out/'raw-rpus.bin.gz').write_bytes(gzip.compress((T.root/'valid.rpus').read_bytes(),mtime=0))
finally:T.doClassCleanups()
