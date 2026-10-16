"""Offline release inventory: group coverage, provenance, and no false green."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).parents[1]/'release_readiness/check.py'


def sha(data):
    return hashlib.sha256(data).hexdigest()


class ReleaseReadinessTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(TOOL.is_file(), 'release readiness checker is not implemented')
        spec=importlib.util.spec_from_file_location('release_readiness',TOOL)
        self.api=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.api)
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        subprocess.run(['git','init','-q',str(self.root)],check=True)
        self.put('packages/core/lib/player.dart',b'original source')
        self.put('requirements.md',b'| CAP-ONE / three | requirement |\n| ERR-01 | error |\n| REG-ONE | policy |\n')
        self.put('report.md',b'Partial historical success; physical acceptance missing.')
        self.manifest={
            'schemaVersion':1,'baselineCommit':'a'*40,
            'requirements':self.ref('requirements.md'),
            'source':self.api.source_snapshot(self.root),
            'evidence':{'report':dict(self.ref('report.md'),kind='report')},
            'rows':[]}
        for req in ['CAP-ONE','ERR-01','REG-ONE']:
            for platform in ['android','ios','macos']:
                self.manifest['rows'].append(self.row(req,platform))
        for req in ['PERF-BASELINE','RELEASE-CONSUMERS','RELEASE-CI']:
            self.manifest['rows'].append(self.row(req,'all'))

    def put(self,path,data):
        target=self.root/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)

    def ref(self,path):
        return {'path':path,'sha256':sha((self.root/path).read_bytes())}

    def row(self,req,platform):
        return dict(requirement=req,platform=platform,implementation='partial',
                    verification='not_run',evidence=['report'],acceptance=None,
                    nextAction='complete-controlled-and-physical-acceptance')

    def check(self):
        return self.api.check(self.root,self.manifest)

    def accept(self,row):
        name=row['requirement']+'-'+row['platform']
        data=dict(schemaVersion=1,requirement=row['requirement'],platform=row['platform'],
                  sourceHash=self.manifest['source']['sha256'],
                  requirementsHash=self.manifest['requirements']['sha256'],coverage='full',outcome='passed',
                  checks=[dict(id='complete-scope',outcome='passed')],artifacts=[self.ref('report.md')])
        path=name+'.json';self.put(path,json.dumps(data).encode())
        self.manifest['evidence'][name]=dict(self.ref(path),kind='acceptance')
        row.update(implementation='implemented',verification='passed',acceptance=name)
        row['evidence'].append(name)
        return path,data

    def test_all_groups_and_failed_skipped_missing_rows_remain_visible(self):
        for row,state in zip(self.manifest['rows'],['failed','skipped','external_missing']):
            row['verification']=state
        result=self.check()
        self.assertEqual(result['rowCount'],12)
        self.assertEqual(result['verificationCounts'],dict(failed=1,skipped=1,external_missing=1,not_run=9,passed=0))
        self.assertFalse(result['releaseReady'])
        self.assertEqual(len(result['blockers']),12)

    def test_missing_duplicate_and_unexpected_requirement_platform_fail(self):
        original=copy.deepcopy(self.manifest)
        for mutation in [lambda m:m['rows'].pop(),lambda m:m['rows'].append(m['rows'][0]),
                         lambda m:m['rows'][0].update(platform='all'),
                         lambda m:m['rows'][0].update(requirement='CAP-OTHER')]:
            self.manifest=copy.deepcopy(original);mutation(self.manifest)
            with self.assertRaises(ValueError):self.check()

    def test_spec_changes_require_explicit_inventory_refresh(self):
        self.put('requirements.md',(self.root/'requirements.md').read_bytes()+b'| CAP-TWO | newly required |\n')
        with self.assertRaises(ValueError):self.check()
        self.manifest['requirements']=self.ref('requirements.md')
        with self.assertRaises(ValueError):self.check()

    def test_historical_report_or_partial_implementation_cannot_be_full_pass(self):
        row=self.manifest['rows'][0]
        row.update(implementation='implemented',verification='passed',acceptance='report')
        with self.assertRaises(ValueError):self.check()
        self.accept(row);row['implementation']='partial'
        with self.assertRaises(ValueError):self.check()

    def test_only_complete_same_source_attestations_can_unlock(self):
        for row in self.manifest['rows']:self.accept(row)
        result=self.check()
        self.assertTrue(result['releaseReady']);self.assertEqual(result['blockers'],[])
        self.assertEqual(result['verificationCounts']['passed'],12)

    def test_relabelled_scope_failed_checks_and_stale_attestations_rejected(self):
        row=self.manifest['rows'][0];path,data=self.accept(row)
        for updates in [dict(platform='ios'),dict(coverage='partial'),dict(outcome='failed'),
                        dict(sourceHash='f'*64),dict(requirementsHash='f'*64),dict(checks=[]),dict(artifacts=[]),
                        dict(checks=[dict(id='one',outcome='skipped')])]:
            changed=dict(data,**updates);self.put(path,json.dumps(changed).encode())
            self.manifest['evidence'][row['acceptance']]=dict(self.ref(path),kind='acceptance')
            with self.subTest(updates=updates),self.assertRaises(ValueError):self.check()

    def test_same_requirement_id_with_new_conditions_invalidates_old_acceptance(self):
        for row in self.manifest['rows']:self.accept(row)
        self.assertTrue(self.check()['releaseReady'])
        original=(self.root/'requirements.md').read_bytes()
        self.put('requirements.md',original.replace(b'| requirement |',
            b'| requirement plus minimum-OS physical validation |'))
        self.manifest['requirements']=self.ref('requirements.md')
        with self.assertRaises(ValueError):self.check()

    def test_source_changes_additions_and_removals_block_without_erasing_history(self):
        for row in self.manifest['rows']:self.accept(row)
        self.put('packages/core/lib/player.dart',b'changed')
        result=self.check();self.assertFalse(result['sourceMatches']);self.assertFalse(result['releaseReady'])
        self.assertEqual(result['verificationCounts']['passed'],12)
        self.assertEqual(result['currentPasses'],0)
        self.put('packages/core/lib/player.dart',b'original source')
        self.put('packages/core/lib/new.dart',b'new');self.assertFalse(self.check()['sourceMatches'])
        (self.root/'packages/core/lib/new.dart').unlink()
        (self.root/'packages/core/lib/player.dart').unlink();self.assertFalse(self.check()['sourceMatches'])

    def test_framework_symlink_identity_and_target_bytes_are_both_bound(self):
        self.put('packages/core/Versions/A/binary',b'v1')
        self.put('packages/core/Versions/B/binary',b'v1')
        link=self.root/'packages/core/Versions/Current';link.symlink_to('A')
        (self.root/'packages/core/binary').symlink_to('Versions/Current/binary')
        first=self.api.source_snapshot(self.root)
        self.put('packages/core/Versions/A/binary',b'v2')
        self.assertNotEqual(first['sha256'],self.api.source_snapshot(self.root)['sha256'])
        self.put('packages/core/Versions/A/binary',b'v1')
        link.unlink();link.symlink_to('B')
        self.assertNotEqual(first['sha256'],self.api.source_snapshot(self.root)['sha256'])

    def test_source_symlink_outside_declared_scope_is_refused(self):
        (self.root/'packages/core/lib/alias').symlink_to(self.root/'report.md')
        with self.assertRaises(ValueError):self.api.source_snapshot(self.root)

    def test_evidence_tampering_missing_file_and_unknown_ref_rejected(self):
        self.put('report.md',b'replaced')
        with self.assertRaises(ValueError):self.check()
        (self.root/'report.md').unlink()
        with self.assertRaises(ValueError):self.check()
        self.manifest['rows'][0]['evidence']=['unregistered']
        with self.assertRaises(ValueError):self.check()

    def test_traversal_absolute_and_symlink_references_are_refused(self):
        for path in ['../private','/private/secret','sub/../report.md']:
            self.manifest['evidence']['report']['path']=path
            with self.subTest(path=path),self.assertRaises(ValueError):self.check()
        self.manifest['evidence']['report']=dict(self.ref('report.md'),kind='report')
        (self.root/'alias.md').symlink_to(self.root/'report.md')
        self.manifest['evidence']['report']['path']='alias.md'
        with self.assertRaises(ValueError):self.check()

    def test_unknown_fields_bad_states_and_empty_next_action_rejected(self):
        original=copy.deepcopy(self.manifest)
        for updates in [dict(verification='unknown'),dict(implementation='unknown'),
                        dict(nextAction=''),dict(url='https://PRIVATE'),dict(evidence=[])]:
            self.manifest=copy.deepcopy(original);self.manifest['rows'][0].update(updates)
            with self.assertRaises(ValueError):self.check()

    def cli(self,*extra):
        return subprocess.run([sys.executable,'-B',str(TOOL),'--root',str(self.root),
                               '--manifest','manifest.json',*extra],capture_output=True,text=True,timeout=10)

    def test_cli_separates_valid_inventory_from_release_gate(self):
        self.put('manifest.json',json.dumps(self.manifest).encode())
        result=self.cli();self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(json.loads(result.stdout)['releaseReady'])
        self.assertEqual(self.cli('--require-ready').returncode,1)
        for row in self.manifest['rows']:self.accept(row)
        self.put('manifest.json',json.dumps(self.manifest).encode())
        self.assertEqual(self.cli('--require-ready').returncode,0)

    def test_cli_invalid_and_oversized_inputs_do_not_echo_private_content(self):
        for data in [b'{"PRIVATE":NaN}',b'{"schemaVersion":1,"schemaVersion":1}',
                     b'PRIVATE'*200000]:
            self.put('manifest.json',data);result=self.cli()
            self.assertEqual(result.returncode,2)
            self.assertEqual(result.stdout,'')
            self.assertNotIn('PRIVATE',result.stderr);self.assertNotIn('Traceback',result.stderr)

if __name__=='__main__':unittest.main()
