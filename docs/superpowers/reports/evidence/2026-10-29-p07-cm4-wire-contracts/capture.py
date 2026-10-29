from pathlib import Path
import gzip,io,json,os,shutil,subprocess
from test_cm4_wire import Cm4WireTests as T
from decoded_alignment import decode
from stream_inventory import file_digest
out=Path('/private/tmp/yl-p07-wire');T.setUpClass()
try:
 t=T('test_real_decode_binds_compressed_state_across_reorder_and_reset');t.test_real_decode_binds_compressed_state_across_reorder_and_reset();t.test_crc_valid_raw_cases_fail_at_parser_or_state_without_trace();t.test_long_coordinate_bits_are_bound_to_correct_frames()
 trace=io.BytesIO();summary=decode(T.media,file_digest(T.media),T.inspector,T.decoder,trace_sink=trace,include_metadata=True)
 (out/'decoded-trace.jsonl.gz').write_bytes(gzip.compress(trace.getvalue(),mtime=0));(out/'decoded-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 oracle=subprocess.check_output([str(T.oracle),str(T.media)],timeout=30);(out/'independent-ffmpeg.jsonl.gz').write_bytes(gzip.compress(oracle,mtime=0))
 receipt={'kind':'synthetic_cm4_wire_only','frames':12,'long_l9_frames':6,'long_l10_frames':6,'all_fields_match_independent_ffmpeg':True,'raw_cases':T.cases,'identities':{}}
 for label,path in [('source',T.source),('synthetic_media',T.media),('raw_rpus',T.root/'valid.rpus'),('mux',T.mux),('decoder',T.decoder),('oracle',T.oracle),('inspector',T.inspector),('fixture',T.fixture)]:
  receipt['identities'][label]={'sha256':file_digest(path),'bytes':path.stat().st_size};shutil.copy2(path,out/('retained-'+label+path.suffix))
 (out/'raw-cases').mkdir(exist_ok=True)
 for case in T.cases:
  path=T.raw_root/case['file'];case['sha256']=file_digest(path);(out/'raw-cases'/(case['file']+'.gz')).write_bytes(gzip.compress(path.read_bytes(),mtime=0))
 (out/'synthetic-verification.json').write_text(json.dumps(receipt,indent=2)+'\n')
finally:T.doClassCleanups()
