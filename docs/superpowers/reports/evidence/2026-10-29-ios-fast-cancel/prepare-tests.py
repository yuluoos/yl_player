from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();s=s.replace('XCTAssertNil(rows.first?["response"])','XCTAssertEqual(rows.first?["cancelCause"] as? Int, 1)\n    XCTAssertNil(rows.first?["response"])',1);s=s.replace('XCTAssertEqual(rows[0]["taskOutcome"] as? Int, 1)','XCTAssertEqual(rows[0]["cancelCause"] as? Int, 4)\n    XCTAssertEqual(rows[0]["taskOutcome"] as? Int, 1)',1);p.write_text(s)
for platform in ('ios','macos'):
 Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_text('@testable import yl_player_media_core\n'+s)
p=Path('tool/playback_network/test_proxy_boundaries.py');p.write_text(p.read_text()+'''

class ProxyCancellationCauseTests(unittest.TestCase):
    def test_v5_preserves_cause_without_waiving_server_correlation(self):
        base=ProxyBoundaryTests();base.setUp()
        row=dict(base.trace,version=5,metrics=None,outcome=1,taskOutcome=1,
            downstreamTerminal=10.33,taskComplete=10.33,cancelCause=2)
        row.pop('serverRequestID')
        result=summarize_proxy_boundaries([row],[base.server],5)
        self.assertFalse(result['fullyCorrelated'])
        self.assertEqual(result['requests'][0]['cancelCause'],2)
        for value in [0,5,True,1.5]:
            with self.subTest(value=value),self.assertRaises(ValueError):
                summarize_proxy_boundaries([dict(row,cancelCause=value)],[base.server],5)
        missing=dict(row);missing.pop('cancelCause')
        with self.assertRaises(ValueError):summarize_proxy_boundaries([missing],[base.server],5)

    def test_v5_success_cannot_be_labelled_as_cancellation(self):
        from test_transaction_metrics import DurationStateTests
        base=ProxyBoundaryTests();base.setUp()
        row=dict(base.trace,version=5,metrics=DurationStateTests().source(),
            downstreamTerminal=10.33,taskComplete=10.32,taskOutcome=0,cancelCause=0)
        self.assertTrue(summarize_proxy_boundaries([row],[base.server],5)['fullyCorrelated'])
        with self.assertRaises(ValueError):summarize_proxy_boundaries([dict(row,cancelCause=1)],[base.server],5)
        with self.assertRaises(ValueError):summarize_proxy_boundaries([dict(row,version=4)],[base.server],4)
''')
Path('docs/superpowers/plans/2026-10-29-fast-cancel.md').write_text('''# 快速取消关联与恢复稳定性\n\n基线 bffe50ea。沿用系统排障、TDD 和集中验收；用户已授权准备后四轮约12分钟前台采集。不发布，不改关联分母或恢复门槛，保留历史失败与设备/授权缺口。\n\n- [ ] 补齐第一次运输终止的取消来源（整体失效/下游EOF/下游错误/其他本地关闭），验证来源不被晚回调覆盖。只完善诊断，不延迟取消或制造服务器请求。\n- [ ] 兼容v1–4，v5严格校验；定向红绿与同制品原生/工具集中测试。\n- [ ] 两轮原配置、两轮重复恢复，按同设备时钟与服务器日志定位快速取消，保存所有失败。\n- [ ] 独立复审、完整证据归档、历史哈希核对及发布台账更新。缺物理资源项不升级验收。\n''')
