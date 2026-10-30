from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text()
a='      XCTAssertEqual(rows.first?["outcome"] as? Double, 1)\n      if downstream {'
b='''      XCTAssertEqual(rows.first?["outcome"] as? Double, 1)
      XCTAssertEqual(rows.first?["version"] as? Int, 7)
      if rows.first?["cancelCause"] as? Int == 3 {
        XCTAssertTrue([1, 3].contains(rows.first?["cancelSource"] as? Int ?? -1))
        XCTAssertEqual(rows.first?["cancelErrorDomain"] as? Int, 1)
        XCTAssertNotEqual(rows.first?["cancelErrorCode"] as? Int, 0)
      } else {
        XCTAssertEqual(rows.first?["cancelSource"] as? Int, 0)
        XCTAssertEqual(rows.first?["cancelErrorDomain"] as? Int, 0)
        XCTAssertEqual(rows.first?["cancelErrorCode"] as? Int, 0)
      }
      if downstream {'''
assert a in s;s=s.replace(a,b)
p.write_text(s)
for platform in ('ios','macos'):Path(f'packages/yl_player/example/{platform}/RunnerTests/{p.name}').write_text('@testable import yl_player_media_core\n'+s)
p=Path('tool/playback_network/test_proxy_boundaries.py')
s=p.read_text()+'''

class ProxyLoopbackErrorSourceTests(unittest.TestCase):
    def source(self):
        base=ProxyBoundaryTests();base.setUp()
        return dict(base.trace,version=7,resourceToken='a'*64,metrics=None,outcome=1,
            taskOutcome=1,downstreamTerminal=10.33,taskComplete=10.33,cancelCause=3,
            cancelSource=1,cancelErrorDomain=1,cancelErrorCode=54),base.server

    def test_v7_preserves_callback_source_and_signed_code_without_inventing_legacy_cause(self):
        from proxy_boundaries import proxy_trace_version
        self.assertEqual(proxy_trace_version([dict(proxyRequestSamplingVersion=7)]),7)
        row,server=self.source()
        for source in (1,2,3):
            for domain,code in ((1,54),(2,-65538),(3,-9806),(4,0)):
                changed=dict(row,cancelSource=source,cancelErrorDomain=domain,cancelErrorCode=code)
                result=summarize_proxy_boundaries([changed],[server],7)['requests'][0]
                self.assertEqual((result['cancelSource'],result['cancelErrorDomain'],result['cancelErrorCode']),(source,domain,code))
        legacy={k:v for k,v in row.items() if k not in ('cancelSource','cancelErrorDomain','cancelErrorCode')}
        legacy['version']=6
        result=summarize_proxy_boundaries([legacy],[server],6)['requests'][0]
        self.assertIsNone(result['cancelSource']);self.assertIsNone(result['cancelErrorCode'])

    def test_v7_rejects_missing_forged_or_inconsistent_error_fields(self):
        row,server=self.source()
        invalid=[dict(row,cancelSource=x) for x in (True,-1,0,4,1.0)]
        invalid += [dict(row,cancelErrorDomain=x) for x in (True,-1,0,5)]
        invalid += [dict(row,cancelErrorCode=x) for x in (True,1.5,2**31,-2**31-1,'private')]
        invalid += [dict(row,cancelCause=4),dict(row,cancelErrorDomain=4,cancelErrorCode=54),dict(row,version=6)]
        invalid += [{k:v for k,v in row.items() if k!=missing} for missing in ('cancelSource','cancelErrorDomain','cancelErrorCode')]
        for broken in invalid:
            with self.subTest(broken=broken),self.assertRaises(ValueError):summarize_proxy_boundaries([broken],[server])

    def test_v7_non_error_close_does_not_acquire_error_source(self):
        row,server=self.source()
        row.update(cancelCause=4,cancelSource=0,cancelErrorDomain=0,cancelErrorCode=0)
        self.assertEqual(summarize_proxy_boundaries([row],[server],7)['requests'][0]['cancelSource'],0)
        row['cancelErrorCode']=54
        with self.assertRaises(ValueError):summarize_proxy_boundaries([row],[server],7)
'''
p.write_text(s)
