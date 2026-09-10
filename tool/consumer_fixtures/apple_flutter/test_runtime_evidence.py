"""Fail-closed main-example XCTest identity, membership and skip regressions."""
import copy
import json
from pathlib import Path
import unittest
import main_example_tests as gate

ROOT = Path(__file__).resolve().parents[3]

class RuntimeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.identity = 'Fixture/testPositive()'
        self.tree = {'testNodes': [{'nodeType': 'Test Case', 'nodeIdentifier': self.identity, 'result': 'Passed'}]}
        self.summary = {'totalTestCount': 1, 'passedTests': 1, 'skippedTests': 0, 'failedTests': 0}

    def verify(self):
        return gate.verify_runtime(self.tree, self.summary, {self.identity}, 'macos')

    def test_exact_runtime_pass(self):
        self.verify()

    def test_omission_cannot_hide_behind_same_count(self):
        self.tree['testNodes'][0]['nodeIdentifier'] = 'Fixture/testOther()'
        with self.assertRaisesRegex(RuntimeError, 'identities'):
            self.verify()

    def test_duplicate_execution_is_not_set_coverage(self):
        self.tree['testNodes'] *= 2
        with self.assertRaisesRegex(RuntimeError, 'duplicate'):
            self.verify()

    def test_unknown_skip_rejected(self):
        self.tree['testNodes'][0]['result'] = 'Skipped'
        with self.assertRaises(RuntimeError):
            self.verify()

    def test_summary_must_match_actual_results(self):
        self.summary['passedTests'] = 0
        with self.assertRaisesRegex(RuntimeError, 'summary'):
            self.verify()

    def test_actual_r19_skip_requires_runtime_capability_attachment(self):
        logs = ROOT / '.superpowers/sdd/2026-09-06-player-v2-apple-hardening/task-4-logs'
        if not (logs / 'ios-final-1-tests.json').exists():
            self.skipTest('local historical focused evidence is not present in CI')
        tree = json.loads((logs / 'ios-final-1-tests.json').read_text())
        nodes = list(gate.case_nodes(tree['testNodes']))
        summary = json.loads((logs / 'ios-final-1-summary.json').read_text())
        with self.assertRaisesRegex(RuntimeError, 'capability'):
            gate.verify_runtime(tree, summary, {n['nodeIdentifier'] for n in nodes}, 'ios')

    def test_r19_exact_conditions(self):
        case = gate.R19_CASE
        node = {'nodeType': 'Test Case', 'nodeIdentifier': case, 'result': 'Skipped', 'children': [{'name': gate.R19_REASON}]}
        tree = {'testNodes': [node]}
        summary = {'totalTestCount': 1, 'passedTests': 0, 'skippedTests': 1, 'failedTests': 0}
        evidence = {case: {'platform': 'iOS Simulator', 'capability': 'fixture=h264_aac.mkv subtype=1635148593 h264=1635148593 hardwareAvailable=false controlledVideo=false'}}
        gate.verify_runtime(tree, summary, {case}, 'ios', evidence)
        for key, value in [('platform', 'iOS'), ('capability', 'hardwareAvailable=false')]:
            invalid = copy.deepcopy(evidence); invalid[case][key] = value
            with self.assertRaises(RuntimeError):
                gate.verify_runtime(tree, summary, {case}, 'ios', invalid)
        node['children'][0]['name'] = 'other decoder error'
        with self.assertRaises(RuntimeError):
            gate.verify_runtime(tree, summary, {case}, 'ios', evidence)

    def test_platform_conditions_do_not_invent_omitted_runtime_cases(self):
        fixtures = ROOT / 'tool/consumer_fixtures/apple_flutter'
        ios = gate.expected_identities(fixtures, 'ios'); macos = gate.expected_identities(fixtures, 'macos')
        case = 'YlAudioOwnershipTests/testMacosDriverTracksOutputWithoutGlobalSession()'
        self.assertIn(case, macos); self.assertNotIn(case, ios)
        case = 'YlAudioOwnershipTests/testActualIosDriverConfiguresMediaSessionAcrossRegistryOwners()'
        self.assertIn(case, ios); self.assertNotIn(case, macos)
        with self.assertRaisesRegex(RuntimeError, 'Unresolved'):
            gate.platform_source('#if canImport(Unknown)\nfunc testUnknown() {}\n#endif', 'ios')

    def test_current_pbx_target_sources_are_exact(self):
        for platform in ['ios', 'macos']:
            pbx = (ROOT / f'packages/yl_player/example/{platform}/Runner.xcodeproj/project.pbxproj').read_text()
            expected = set(gate.accepted_tests(ROOT / 'tool/consumer_fixtures/apple_flutter', platform))
            gate.verify_pbx_membership(pbx, expected)
            damaged = pbx.replace('YlManagedFallbackCharacterizationTests.swift in Sources', 'Missing.swift in Sources')
            with self.assertRaises(RuntimeError):
                gate.verify_pbx_membership(damaged, expected)

if __name__ == '__main__':
    unittest.main()
