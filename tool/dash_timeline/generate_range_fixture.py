#!/usr/bin/env python3
"""Owned Range regression: preserve absolute tfhd offsets across a sparse gap.

Keep original encoded samples. Drop redundant local indexes, enlarge tfhd and
trun addressing, and emit an authoritative global sidx plus SegmentList mirror.
"""
from pathlib import Path
import struct,json,hashlib,subprocess
root=Path(__file__).resolve().parents[2]/'packages/yl_player/example/assets/test_media/dash_timeline'
def box(t,p):return struct.pack('>I4s',len(p)+8,t)+p
def boxes(b):
 pos=0
 while pos<len(b):
  n,t=struct.unpack_from('>I4s',b,pos);assert n>=8 and pos+n<=len(b)
  yield t,b[pos+8:pos+n]
  pos+=n

def absolute(b,start):
 def patch(data,offset):
  out=b''
  for t,p in boxes(data):
   if t==b'moof':p=patch(p,start+len(out))
   elif t==b'traf':p=patch(p,offset)
   elif t==b'tfhd':
    flags=struct.unpack_from('>I',p)[0];assert not flags&1
    p=struct.pack('>I',(flags&~0x020000)|1)+p[4:8]+struct.pack('>Q',offset)+p[8:]
   elif t==b'trun':
    flags=struct.unpack_from('>I',p)[0];assert flags&1
    p=p[:8]+struct.pack('>i',struct.unpack_from('>i',p,8)[0]+8)+p[12:]
   elif t==b'sidx':continue
   out+=box(t,p)
  return out
 # Remove local sidx before determining moof's absolute offset.
 filtered=b''.join(box(t,p) for t,p in boxes(b) if t!=b'sidx')
 return patch(filtered,start)
init=(root/'period0/init-0.m4s').read_bytes()
indexSize=80;hole=box(b'free',bytes(4096-8));start=len(init)+indexSize+len(hole)
frags=[];ranges=[]
for i in range(1,5):
 f=absolute((root/f'period0/chunk-0-{i:05}.m4s').read_bytes(),start)
 ranges.append((start,start+len(f)-1));start+=len(f);frags.append(f)
body=struct.pack('>IIIIIHH',0,1,12288,0,len(hole),0,4)+b''.join(struct.pack('>III',len(f),12288,0x90000000) for f in frags)
index=box(b'sidx',body);assert len(index)==indexSize
(root/'absolute-range.m4s').write_bytes(init+index+hole+b''.join(frags))
head='<MPD type="static" mediaPresentationDuration="PT4S"><Period duration="PT4S"><AdaptationSet contentType="video" mimeType="video/mp4"><Representation id="v" codecs="avc1.42c01e" width="320" height="180" bandwidth="350000"><BaseURL>absolute-range.m4s</BaseURL>'
base=f'<SegmentBase indexRange="{len(init)}-{len(init)+len(index)-1}"><Initialization range="0-{len(init)-1}"/></SegmentBase>'
listing=f'<SegmentList timescale="12288" duration="12288"><Initialization range="0-{len(init)-1}"/>'+''.join(f'<SegmentURL mediaRange="{a}-{b}"/>' for a,b in ranges)+'</SegmentList>'
for name,element in [('absolute-base',base),('absolute-list',listing)]:
 (root/(name+'.mpd')).write_text(head+element+'</Representation></AdaptationSet></Period></MPD>\n')
files=['absolute-range.m4s', 'absolute-base.mpd', 'absolute-list.mpd']
(root/'range-fixture-provenance.json').write_text(json.dumps({'source':'period0 original owned AVC; sample payloads unchanged', 'files':{name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in files}}, indent=2)+'\n')
