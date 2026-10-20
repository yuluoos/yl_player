"""Offline, hash-bound RGB float32 comparison; does not certify Dolby output."""
import argparse
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import re

MAX_JSON = 2*1024*1024
MAX_PIXELS = 4096*2160
MAX_FRAMES = 32
DOMAINS = ('linear_nits_bt2020','linear_nits_p3d65','linear_nits_bt709')
THRESHOLDS = {'max_abs_nits','rmse_nits','p99_abs_nits'}
ROLES = {'provenance','frame_alignment','target_generation','threshold_basis'}


class ComparisonError(ValueError):
    def __init__(self):
        super().__init__('dolby.reference_comparison_invalid')


class DependencyError(ComparisonError):
    pass


def require(value):
    if not value:
        raise ComparisonError()


def number(value):
    require(type(value) in (int,float) and math.isfinite(value) and value >= 0)
    return value


def uint(value):
    require(type(value) is int and 0 <= value < 2**63)
    return value


def sha(value):
    require(type(value) is str and re.fullmatch('[a-f0-9]{64}',value))
    return value


def timestamp(value):
    require(type(value) is list and len(value)==2)
    numerator,denominator=value
    require(type(numerator) is int and -2**63 <= numerator < 2**63)
    require(uint(denominator)>0)
    return Fraction(numerator,denominator)


def rectangle(value,width,height):
    require(type(value) is list and len(value)==4)
    x,y,w,h=map(uint,value)
    require(w>0 and h>0 and x+w<=width and y+h<=height)
    return value


def asset(value):
    require(type(value) is dict and set(value)=={'path','sha256'})
    require(type(value['path']) is str and 0<len(value['path'])<=1024)
    sha(value['sha256'])


def target(value):
    require(type(value) is dict and set(value)=={'peak_nits','black_nits','primaries','white_point','transfer','ambient_lux'})
    require(0<number(value['peak_nits'])<=10000)
    require(number(value['black_nits'])<value['peak_nits'])
    number(value['ambient_lux'])
    require(value['primaries'] in ('bt2020','p3d65','bt709'))
    require(value['transfer'] in ('pq','hlg','linear'))
    white=value['white_point'];require(type(white) is list and len(white)==2)
    require(0<number(white[0])<1 and 0<number(white[1])<1 and sum(white)<1)


def validate_contract(c):
    require(type(c) is dict and type(c.get('schema_version')) is int and c['schema_version']==1)
    require(c['mode'] in ('candidate','reviewed_reference'))
    sha(c['source_sha256'])
    width,height=uint(c['width']),uint(c['height'])
    require(0<width<=8192 and 0<height<=8192 and width*height<=MAX_PIXELS)
    require(c['domain'] in DOMAINS);target(c['target'])
    rectangle(c['active_area'],width,height)
    require(type(c['regions']) is list and 2<=len(c['regions'])<=32)
    names={'full','active'};kinds=set()
    for region in c['regions']:
        require(type(region) is dict and set(region)=={'name','kind','rect'})
        name=region['name'];require(type(name) is str and re.fullmatch('[a-z][a-z0-9_]{0,47}',name) and name not in names)
        names.add(name);require(region['kind'] in ('boundary','chroma_edge'));kinds.add(region['kind'])
        rectangle(region['rect'],width,height)
    require(kinds=={'boundary','chroma_edge'})
    require(type(c['thresholds']) is dict and set(c['thresholds'])==THRESHOLDS)
    for value in c['thresholds'].values():number(value)
    require(type(c['evidence']) is list and len(c['evidence'])<=16)
    roles=set()
    for proof in c['evidence']:
        require(type(proof) is dict and set(proof)=={'role','path','sha256'})
        require(proof['role'] in ROLES and proof['role'] not in roles);roles.add(proof['role'])
        asset({key:proof[key] for key in ('path','sha256')})
    require(type(c['frames']) is list and 0<len(c['frames'])<=MAX_FRAMES)
    identifiers=set();metadata=set();previous=None
    for frame in c['frames']:
        require(type(frame) is dict and set(frame)=={'id','pts','metadata_sha256','reference'})
        identity=uint(frame['id']);require(identity not in identifiers);identifiers.add(identity)
        pts=timestamp(frame['pts']);require(previous is None or pts>previous);previous=pts
        metadata.add(sha(frame['metadata_sha256']));asset(frame['reference'])
    if c['mode']=='reviewed_reference':
        require(roles==ROLES and len(c['frames'])>=2 and len(metadata)>=2)
    return c


def read_limited(path,limit):
    require(path.is_file())
    with path.open('rb') as source:data=source.read(limit+1)
    require(len(data)<=limit)
    return data


def json_object(pairs):
    result={}
    for key,value in pairs:
        require(key not in result);result[key]=value
    return result


def parse_json(data):
    def invalid_constant(_):raise ComparisonError()
    try:
        return json.loads(data,object_pairs_hook=json_object,parse_constant=invalid_constant)
    except (ValueError,UnicodeError,RecursionError):
        raise ComparisonError() from None


def resolve_path(path):
    # Python 3.12 raises RuntimeError for symlink loops (newer versions use OSError).
    try:
        return Path(path).resolve(strict=True)
    except RuntimeError:
        raise ComparisonError() from None


def bound_asset(root,descriptor,limit):
    asset(descriptor)
    relative=Path(descriptor['path'])
    require(not relative.is_absolute() and '..' not in relative.parts)
    path=resolve_path(root/relative)
    require(path.is_relative_to(root))
    data=read_limited(path,limit)
    require(hashlib.sha256(data).hexdigest()==descriptor['sha256'])
    return data


def capture_matches(c,capture,contract_sha):
    require(type(capture) is dict and type(capture.get('schema_version')) is int and capture['schema_version']==1)
    require(capture['contract_sha256']==contract_sha)
    target(capture['target'])
    for key in ('source_sha256','domain','target','width','height'):
        require(capture[key]==c[key])
    uint(capture['width']);uint(capture['height']);sha(capture['source_sha256'])
    generation=uint(capture['display_generation'])
    frames=capture['frames'];require(type(frames) is list and len(frames)==len(c['frames']))
    for reference,actual in zip(c['frames'],frames):
        require(type(actual) is dict and set(actual)=={'id','pts','metadata_sha256','display_generation','actual'})
        require(uint(actual['id'])==reference['id'])
        require(timestamp(actual['pts'])==timestamp(reference['pts']))
        require(sha(actual['metadata_sha256'])==reference['metadata_sha256'])
        require(uint(actual['display_generation'])==generation)
        asset(actual['actual'])


def region_metrics(np,actual,reference,rect):
    x,y,w,h=rect
    # No clamping, normalization, exposure matching, resampling or color conversion.
    error=np.abs(np.subtract(actual[y:y+h,x:x+w],reference[y:y+h,x:x+w],dtype=np.float64))
    flat=error.ravel()
    maximum=int(np.argmax(flat));row,column,channel=np.unravel_index(maximum,error.shape)
    rmse=math.sqrt(float(np.dot(flat,flat))/flat.size)
    # Nearest-rank p99, with one-based rank ceil(0.99*N).
    rank=(99*flat.size+99)//100-1
    quantile=float(np.partition(flat,rank)[rank])
    return {'max_abs_nits':float(flat[maximum]),'rmse_nits':rmse,'p99_abs_nits':quantile,
            'max_error_at':[int(column)+x,int(row)+y,int(channel)],'channel_samples':int(flat.size)}


def compare_bundle(contract_path,expected_sha,capture_path):
    contract_path=resolve_path(contract_path)
    capture_path=resolve_path(capture_path)
    raw=read_limited(contract_path,MAX_JSON)
    require(hashlib.sha256(raw).hexdigest()==sha(expected_sha))
    c=validate_contract(parse_json(raw))
    capture_raw=read_limited(capture_path,MAX_JSON);capture=parse_json(capture_raw)
    capture_matches(c,capture,expected_sha)
    for proof in c['evidence']:
        bound_asset(contract_path.parent,{key:proof[key] for key in ('path','sha256')},4*1024*1024)
    try:
        import numpy as np
    except ImportError:
        raise DependencyError() from None
    size=c['width']*c['height']*3*4
    regions={'full':[0,0,c['width'],c['height']],'active':c['active_area']}
    regions.update({r['name']:r['rect'] for r in c['regions']})
    results=[];passed=True
    for ref,actual in zip(c['frames'],capture['frames']):
        values=[]
        for root,descriptor in [(contract_path.parent,ref['reference']),(capture_path.parent,actual['actual'])]:
            data=bound_asset(root,descriptor,size)
            require(len(data)==size)
            value=np.frombuffer(data,dtype='<f4').reshape(c['height'],c['width'],3)
            require(bool(np.isfinite(value).all()))
            values.append(value)
        metrics={name:region_metrics(np,values[1],values[0],rect) for name,rect in regions.items()}
        for metric in metrics.values():
            metric['thresholds_met']=all(metric[key]<=limit for key,limit in c['thresholds'].items())
            passed=passed and metric['thresholds_met']
        results.append({'id':ref['id'],'pts':ref['pts'],'reference_sha256':ref['reference']['sha256'],
                        'actual_sha256':actual['actual']['sha256'],'regions':metrics})
    status=('pass' if passed else 'fail') if c['mode']=='reviewed_reference' else 'diagnostic'
    return {'schema_version':1,'contract_sha256':expected_sha,
            'capture_manifest_sha256':hashlib.sha256(capture_raw).hexdigest(),
            'comparison_status':status,'numeric_thresholds_met':passed,
            'reference_mode':c['mode'],'numpy_version':np.__version__,
            'mapping_quality_pass':None,'native_dv_signal_pass':None,
            'acceptance':'separate_review_required','display_generation':capture['display_generation'],
            'frames':results}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--contract',type=Path,required=True)
    parser.add_argument('--sha256',required=True,help='Previously frozen contract SHA-256')
    parser.add_argument('--capture',type=Path,required=True)
    args=parser.parse_args()
    try:
        result=compare_bundle(args.contract,args.sha256,args.capture)
        print(json.dumps(result,sort_keys=True,indent=2,allow_nan=False))
        return {'pass':0,'fail':1,'diagnostic':3}[result['comparison_status']]
    except DependencyError:
        print('{"code":"dolby.reference_numpy_missing"}')
        return 2
    except (ComparisonError,OSError,ValueError,KeyError,TypeError,OverflowError,RecursionError):
        print('{"code":"dolby.reference_comparison_invalid"}')
        return 2


if __name__=='__main__':
    raise SystemExit(main())
