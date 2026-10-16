from pathlib import Path
import sys,json,hashlib,subprocess,time
root=Path('/private/tmp/yl-p07-metadata/yl_player');sys.path.insert(0,str(root/'tool/dolby_reference'))
from stream_inventory import inspect,InspectionError
original=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player/.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes/sol-levante-p5-1080p.mp4')
parser=Path('/private/tmp/yl-p07-metadata/native-green/target/release/yl-dovi-stream-inspector')
with original.open('rb') as f:data=f.read(454604)
rows=[]
for corrected in (False,True):
    variant=bytearray(data)
    if corrected:
        offset=0
        while offset<len(variant):
            size=int.from_bytes(variant[offset:offset+4],'big');kind=variant[offset+4:offset+8]
            if kind==b'mdat':
                assert size not in (0,1)
                variant[offset:offset+4]=(len(variant)-offset).to_bytes(4,'big');break
            assert size>=8
            offset+=size
        else:raise AssertionError('mdat missing')
    path=Path('/private/tmp/yl-p07-metadata')/('truncated-size-corrected.mp4' if corrected else 'truncated.mp4');path.write_bytes(variant)
    probe=subprocess.run(['ffprobe','-v','error','-show_streams','-show_packets','-select_streams','v','-show_entries','stream=nb_frames:packet=pos,size','-of','json',str(path)],capture_output=True,text=True,check=True)
    parsed=json.loads(probe.stdout)
    result={'case':'corrected_box_still_missing_samples' if corrected else 'original_declared_box_exceeds_eof','media_bytes':len(variant),'sha256':hashlib.sha256(variant).hexdigest(),'ffprobe_exit':probe.returncode,'ffprobe_stderr_bytes':len(probe.stderr),'declared_samples':parsed['streams'][0]['nb_frames'],'returned_packets':len(parsed['packets'])}
    try:
        report=inspect(path,result['sha256'],parser)
        result.update(accepted=True,reported_packets=report['packet_count'])
    except InspectionError:result.update(accepted=False)
    rows.append(result)
print(json.dumps({'phase':sys.argv[1],'cases':rows},indent=2))
assert all(row['accepted']==(sys.argv[1]=='red') for row in rows)
