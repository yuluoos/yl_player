#!/usr/bin/env python3
"""Validate versioned P08 thresholds and current-source comparisons; pending is not ready."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
from performance_gate import require, fields, label, hash_value, read_json, digest, evaluate, MAX_BYTES


def reference(root, value):
    fields(value,'path sha256');hash_value(value['sha256'])
    name=value['path'];require(isinstance(name,str))
    path=PurePosixPath(name)
    require(not path.is_absolute() and path.as_posix()==name and all(p not in ('.','..','') for p in name.split('/')))
    target=Path(root)
    for part in path.parts:
        target=target/part;require(not target.is_symlink())
    with target.open('rb') as stream:data=stream.read(MAX_BYTES+1)
    require(len(data)<=MAX_BYTES and hashlib.sha256(data).hexdigest()==value['sha256'])
    return read_json(target)


def matches_profile(conditions, profile):
    if any(conditions.get(key)!=profile[key] for key in ('platform','deviceKind')): return False
    constraints=profile['constraints']
    if 'architectures' in constraints and conditions.get('architecture') not in constraints['architectures']: return False
    if 'osMajor' in constraints:
        major=conditions.get('os','').split('.')[0]
        if major!=str(constraints['osMajor']): return False
    return all(conditions.get(key)==constraints[key] for key in ('apiLevel','processBits','memoryClass') if key in constraints)


def validate_constraints(constraints):
    fields(constraints,'','osMajor architectures apiLevel processBits memoryClass')
    require(bool(constraints))
    from performance_gate import integer
    for key in ('osMajor','apiLevel'):
        if key in constraints: require(integer(constraints[key],1,1000))
    if 'architectures' in constraints:
        values=constraints['architectures']
        require(isinstance(values,list) and 0<len(values)<=10)
        for value in values: label(value)
        require(len(set(values))==len(values))
    if 'processBits' in constraints: require(type(constraints['processBits']) is int and constraints['processBits'] in (32,64))
    if 'memoryClass' in constraints: require(constraints['memoryClass'] in ('low','standard'))


def check(registry,root):
    fields(registry,'schemaVersion status entries requiredProfiles')
    require(type(registry['schemaVersion']) is int and registry['schemaVersion']==1)
    require(registry['status'] in ('pending-qualified-baselines','frozen'))
    profiles=registry['requiredProfiles'];entries=registry['entries']
    require(isinstance(profiles,list) and 0<len(profiles)<=100)
    require(isinstance(entries,list) and len(entries)<=len(profiles))
    by_id={}
    for profile in profiles:
        fields(profile,'id platform deviceKind constraints nextAction')
        validate_constraints(profile['constraints'])
        label(profile['id']);label(profile['nextAction'])
        require(profile['id'] not in by_id and profile['platform'] in ('android','ios','macos'))
        require(profile['deviceKind'] in ('physical','simulator','emulator'))
        by_id[profile['id']]=profile
    seen=set();blockers=[];passed=0
    for entry in entries:
        fields(entry,'profile frozen candidate sources')
        key=entry['profile'];require(isinstance(key,str) and key in by_id and key not in seen);seen.add(key)
        frozen=reference(root,entry['frozen']);candidate=reference(root,entry['candidate']);sources=reference(root,entry['sources'])
        require(digest(sources)==candidate['sourceHash'])
        from run_public_stress import source_identity
        current=source_identity(Path(root))
        result=evaluate(candidate,frozen)
        profile=by_id[key]
        require(matches_profile(candidate['conditions'],profile))
        if sources!=current:
            blockers.append(dict(profile=key,reason='source-changed',nextAction=profile['nextAction']))
        elif not result['passed']:
            blockers.append(dict(profile=key,reason='threshold-failed',nextAction=profile['nextAction']))
        else:passed+=1
    for key in by_id.keys()-seen:
        blockers.append(dict(profile=key,reason='baseline-missing',nextAction=by_id[key]['nextAction']))
    return dict(schemaVersion=1,ready=not blockers and registry['status']=='frozen',
                passed=passed,profiles=len(profiles),blockers=sorted(blockers,key=lambda x:x['profile']))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--registry',default='tool/playback_benchmark/thresholds.json')
    parser.add_argument('--require-ready',action='store_true');args=parser.parse_args()
    try:
        result=check(read_json(args.root/args.registry),args.root)
        print(json.dumps(result,sort_keys=True,indent=2))
        return 1 if args.require_ready and not result['ready'] else 0
    except (OSError,ValueError,TypeError,KeyError,RecursionError):
        print('Invalid threshold registry; check coverage, evidence and source identity.',file=sys.stderr);return 2

if __name__=='__main__':sys.exit(main())
