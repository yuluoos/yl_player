from pathlib import Path
import hashlib,json,sys
root=Path.cwd();sys.path.insert(0,str(root/'tool/dolby_reference'))
from stream_inventory import inspect
from reference_timeline import verify_publisher_asset,parse_mdf,locate_frame,exr_header
out=Path('/private/tmp/p07-main-merge-20261020')
cache=Path('/Users/yy2021_8689/.codex/worktrees/p07-engineering/yl_player/.superpowers/sdd/2026-10-20-p07-public-resources/resources')
research=cache.parents[1]/'2026-10-20-p07-reference-comparison'
inspector=Path('/private/tmp/p07-engineering-20261020/inspector-build/target/release/yl-dovi-stream-inspector')
for name,media,expected,layers in [
 ('p5',root/'.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes/sol-levante-p5-1080p.mp4','87fe0115f3002a621d2380a9f91852ef91a15854a446efe26de8744f77ef5346',False),
 ('p7',cache/'fel-test-st-dl-p7-cmv4-v4.mp4','419fc183988cb57b0cac2907a01d9f43b1a5ec34012b4c0655574d77678ee4fa',True)]:
    result=inspect(media,expected,inspector,include_layers=layers)
    stored=json.loads((root/'tool/dolby_reference'/('fel-observation.json' if layers else 'stream-observation.json')).read_text())
    expected_result=stored.get('result',stored)
    # Observations may include provenance fields; every returned field is checked.
    for key,value in result.items():
        if key!='inspector_sha256':assert value==expected_result[key],(name,key)
    (out/f'{name}-regression.json').write_text(json.dumps(result,indent=2)+'\n')
    print(name,result['packet_count'],'summary and trace hash unchanged',flush=True)
checksum=(research/'official-checksum.txt').read_bytes()
identity=verify_publisher_asset(cache/'sparks-input-01000.exr','f34e1c18693c3bb6d218936b1957bf392a0f2888beda81c7dbf8a631aec75285',checksum,'b5cdc1d6274fe5ae2696e04c00942f7024d6c2c9e36d7cdf19854acd6ccab493','sparks_vdm_hdr_p3d65_pq_20161026_01_4096x2160_dovi_4000nit_0001000.exr')
timeline=parse_mdf((cache/'sparks-metadata.xml').read_bytes());frame=locate_frame(timeline,1000)
with (cache/'sparks-input-01000.exr').open('rb') as f:header=exr_header(f.read(4096))
head960=exr_header((research/'exr-960.bin').read_bytes())
assert header['timecode_raw']==head960['timecode_raw']=='0016000000000000'
assert frame['time']==[1001,60] and frame['shot_frame_offset']==83
(out/'reference-binding.json').write_text(json.dumps({'identity':identity,'frame_1000':frame,'timecode_alias_960_1000':True,'cross_sequence_alignment_verified':False},indent=2)+'\n')
print('publisher identity/XML location/timecode alias verified; independent target remains unresolved',flush=True)
