"""Parse macOS vmmap report 7 summaries, retaining rounded display units."""
import re

SIZE = r'(?:0|[1-9][0-9]*)(?:\.[0-9]+)?[KMGT]?'
COLUMNS = ('virtualSize','residentSize','dirtySize','swappedSize',
           'volatileSize','nonvolatileSize','emptySize')
HEADER = 'VIRTUAL RESIDENT DIRTY SWAPPED VOLATILE NONVOL EMPTY REGION'
SUBHEADER = 'REGION TYPE SIZE SIZE SIZE SIZE SIZE SIZE SIZE COUNT (non-coalesced)'


def probe_identity(row, run_id, workload):
    if (not isinstance(row,dict) or row.get('runId')!=run_id
        or type(row.get('schemaVersion')) is not int or row['schemaVersion']!=2
        or row.get('buildMode')!='profile' or row.get('workload')!=workload
        or type(row.get('plannedAttempts')) is not int or row['plannedAttempts']!=10
        or type(row.get('attempt')) is not int or not 1<=row['attempt']<=10
        or type(row.get('pid')) is not int or not 1<=row['pid']<=2**31-1):
        raise ValueError('Unexpected resource process identity')
    return row['attempt'],row['pid']


def parse_vmmap(text, expected_pid):
    if not isinstance(text,str) or len(text)>2*1024*1024:
        raise ValueError('Invalid memory report size')
    lines=text.splitlines()
    if (type(expected_pid) is not int or expected_pid<1
        or len(re.findall(r'^Process: +yl_player_example \['+str(expected_pid)+r'\] *$',text,re.M))!=1
        or len(re.findall(r'^Report Version: +7 *$',text,re.M))!=1):
        raise ValueError('Unexpected memory report identity or version')
    footprint=re.findall(r'^Physical footprint: +('+SIZE+r') *$',text,re.M)
    normalized=[' '.join(line.split()) for line in lines]
    if len(footprint)!=1 or normalized.count(HEADER)!=1:
        raise ValueError('Missing memory summary')
    start=normalized.index(HEADER)
    if (start+3>=len(lines) or normalized[start+1]!=SUBHEADER
        or not re.fullmatch(r'[= ]+',lines[start+2])):
        raise ValueError('Unexpected memory columns')
    regions={};complete=False
    for line in lines[start+3:]:
        if re.fullmatch(r'[= ]+',line):
            complete=True;break
        match=re.fullmatch(r'([A-Za-z_][A-Za-z0-9_ ()/.,+-]{0,95}?)\s+'
            +r'\s+'.join(['('+SIZE+')']*7)+r'\s+([0-9]+)'
            +r'(?:\s+(?:see MALLOC ZONE table below|reserved VM address space \(unallocated\)))?\s*',line)
        if not match:raise ValueError('Invalid memory region row')
        name=match[1].strip()
        if name in regions:raise ValueError('Duplicate memory region')
        regions[name]=dict(zip(COLUMNS,match.groups()[1:8]),regionCount=int(match[9]))
    if not complete or not regions:raise ValueError('Incomplete memory region table')
    return dict(reportVersion=7,pid=expected_pid,physicalFootprint=footprint[0],
                regions=regions,exactBytes=False,leakVerdict=None,
                performanceBaseline=False,budgetAdmission=False)
