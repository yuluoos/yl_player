"""Bounded MDF timeline/EXR header research; never infers cross-sequence alignment."""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re
import struct
import xml.etree.ElementTree as ET

MAX_XML = 4 * 1024 * 1024
MAX_HEADER = 65536


class ReferenceError(ValueError):
    def __init__(self):
        super().__init__('dolby.reference_invalid')


def require(value):
    if not value:
        raise ReferenceError()


def uint(value):
    require(type(value) is int or (type(value) is str and re.fullmatch(r'[0-9]{1,19}', value)))
    value = int(value)
    require(0 <= value < 2**63)
    return value


def one(parent, path):
    found = parent.findall(path)
    require(len(found) == 1)
    return found[0]


def integer_child(parent, path):
    return uint(one(parent, path).text)


def parse_mdf(data):
    require(type(data) is bytes and 0 < len(data) <= MAX_XML)
    # The supported UTF-8 subset has no DTD, entity or namespace expansion.
    require(b'<!DOCTYPE' not in data.upper() and b'<!ENTITY' not in data.upper())
    try:
        text = data.decode('utf-8-sig')
        require('\x00' not in text)
        root = ET.fromstring(text)
        require(root.tag == 'DolbyLabsMDF' and root.get('version') == '2.0.5')
        track = one(one(root, './Outputs/Output'), './Video/Track')
        rate_node = one(track, 'Rate')
        numerator, denominator = integer_child(rate_node,'n'), integer_child(rate_node,'d')
        require(0 < numerator <= 10**9 and 0 < denominator <= 10**9)
        rate = Fraction(numerator, denominator)
        displays, target_ids = [], set()
        for node in track.findall('./PluginNode/DolbyEDR/Characteristics/TargetDisplay'):
            identifier = str(integer_child(node, 'ID'))
            require(identifier not in target_ids)
            target_ids.add(identifier)
            displays.append({'id':identifier, 'name':node.findtext('Name'),
                             'peak_brightness':node.findtext('PeakBrightness'),
                             'minimum_brightness':node.findtext('MinimumBrightness'),
                             'encoding':node.findtext('Encoding'),
                             'primaries':{name:node.findtext('Primaries/'+name)
                                          for name in ('Red','Green','Blue')}})
        require(displays)
        shots, end = [], 0
        for shot in track.findall('Shot'):
            require(len(shots) < 32768)
            record = one(shot,'Record')
            start, duration = integer_child(record,'In'), integer_child(record,'Duration')
            require(start == end and duration > 0 and start+duration < 2**63)
            trims = [str(integer_child(node,'TID')) for node in
                     shot.findall('./PluginNode/DolbyEDR[@level="2"]')]
            require(len(trims) == len(set(trims)) and set(trims) <= target_ids)
            end = start+duration
            shots.append({'start':start,'end':end,'signalled_trim_targets':trims})
        require(shots)
        return {'schema_version':1,'xml_sha256':hashlib.sha256(data).hexdigest(),
                'rate':[rate.numerator,rate.denominator], 'frame_count':end,
                'targets':displays,'shots':shots}
    except (ET.ParseError, UnicodeError, TypeError, AttributeError):
        raise ReferenceError() from None


def locate_frame(timeline, frame):
    frame = uint(frame)
    require(frame < timeline['frame_count'])
    rate = Fraction(*timeline['rate'])
    for index, shot in enumerate(timeline['shots']):
        if shot['start'] <= frame < shot['end']:
            time = Fraction(frame, 1) / rate
            return {'frame_index':frame,'shot_index':index,
                    'shot_frame_offset':frame-shot['start'],
                    'time':[time.numerator,time.denominator],
                    'signalled_trim_targets':shot['signalled_trim_targets'],
                    'cross_sequence_alignment_verified':False}
    raise ReferenceError()


def locate_pts(timeline, pts, time_base):
    require(type(time_base) is list and len(time_base) == 2)
    numerator, denominator = map(uint,time_base)
    require(numerator > 0 and denominator > 0)
    frame = uint(pts) * Fraction(numerator,denominator) * Fraction(*timeline['rate'])
    require(frame.denominator == 1)
    return locate_frame(timeline,frame.numerator)


def exr_header(data):
    require(type(data) is bytes and 9 <= len(data) <= MAX_HEADER)
    try:
        magic, version = struct.unpack_from('<II',data)
        require(magic == 20000630 and version == 2)
        offset, attributes = 8, {}
        while data[offset]:
            require(len(attributes) < 128)
            fields = []
            for _ in range(2):
                end = data.index(0,offset)
                require(0 < end-offset <= 255)
                fields.append(data[offset:end].decode('ascii'));offset=end+1
            name, kind = fields
            require(name not in attributes)
            size = struct.unpack_from('<I',data,offset)[0];offset+=4
            require(size <= MAX_HEADER and offset+size < len(data))
            attributes[name]=(kind,data[offset:offset+size]);offset+=size
        result = {'frame_index':None, 'rate':None,'data_window':None,
                  'timecode_raw':None, 'attribute_names':sorted(attributes)}
        if 'framesPerSecond' in attributes:
            kind, value=attributes['framesPerSecond'];require(kind=='rational' and len(value)==8)
            n,d=struct.unpack('<iI',value);require(n>0 and d>0)
            result['rate']=[n,d]
        if 'dataWindow' in attributes:
            kind,value=attributes['dataWindow'];require(kind=='box2i' and len(value)==16)
            window=list(struct.unpack('<4i',value));require(window[2]>=window[0] and window[3]>=window[1])
            result['data_window']=window
        if 'timeCode' in attributes:
            kind,value=attributes['timeCode'];require(kind=='timecode' and len(value)==8)
            result['timecode_raw']=value.hex()
        return result
    except (IndexError, struct.error, UnicodeError, ValueError):
        raise ReferenceError() from None


def verify_publisher_asset(path, expected_sha256, checksum, checksum_sha256, filename):
    """The publisher's legacy MD5 identifies an asset; SHA-256 freezes both inputs.

    This is a byte identity check, not proof of mastering, alignment or quality.
    """
    require(type(checksum) is bytes and 0<len(checksum)<=MAX_XML)
    require(hashlib.sha256(checksum).hexdigest()==checksum_sha256)
    require(type(filename) is str and 0<len(filename)<=255)
    try:
        entries=[line.split('\t') for line in checksum.decode('utf-8').splitlines()]
    except UnicodeError:
        raise ReferenceError() from None
    matches=[entry for entry in entries if entry and entry[0]==filename]
    require(len(matches)==1 and len(matches[0])==4)
    _,size,algorithm,expected_md5=matches[0]
    size=uint(size);require(0<size<=512*1024*1024 and algorithm=='md5')
    require(re.fullmatch('[a-f0-9]{32}',expected_md5))
    require(type(expected_sha256) is str and re.fullmatch('[a-f0-9]{64}',expected_sha256))
    total=0;sha256=hashlib.sha256();md5=hashlib.md5(usedforsecurity=False)
    require(Path(path).is_file())
    with Path(path).open('rb') as source:
        while chunk:=source.read(65536):
            total+=len(chunk);require(total<=size);sha256.update(chunk);md5.update(chunk)
    require(total==size and sha256.hexdigest()==expected_sha256 and md5.hexdigest()==expected_md5)
    return {'publisher_checksum_matches':True,'publisher_filename':filename,
            'publisher_md5':expected_md5,'media_sha256':expected_sha256,
            'checksum_sha256':checksum_sha256,'bytes':total,
            'cross_sequence_alignment_verified':False}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xml',type=Path,required=True)
    parser.add_argument('--sha256',required=True)
    parser.add_argument('--frame',type=int,required=True)
    args=parser.parse_args()
    try:
        with args.xml.open('rb') as source:data=source.read(MAX_XML+1)
        require(hashlib.sha256(data).hexdigest()==args.sha256)
        timeline=parse_mdf(data)
        print(json.dumps({'timeline':timeline,'selected_frame':locate_frame(timeline,args.frame)},sort_keys=True,indent=2))
        return 0
    except (ReferenceError,OSError,ValueError,KeyError,TypeError):
        print('{"code":"dolby.reference_invalid"}')
        return 2


if __name__=='__main__':
    raise SystemExit(main())
