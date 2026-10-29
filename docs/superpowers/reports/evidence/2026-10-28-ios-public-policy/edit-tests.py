from pathlib import Path
p=Path('tool/playback_network/test_abr_accesslog.py')
s=p.read_text();at=s.index('    def test_policy_scenarios_require_preroll_preparation')
s=s[:at]+'''    def test_public_policy_cycle_requires_every_committed_phase_and_actual_frames(self):
        phases = ['initial-auto', 'caps', 'clear-caps', 'fixed', 'restore-auto']
        rows = []
        frames = []
        for i, phase in enumerate(phases):
            for j in range(4):
                elapsed = i * 10 + j
                fixed = 'dash-video-w320-h180-b350000' if phase == 'fixed' else None
                rows.append(dict(elapsed=elapsed, publicPolicyCycle=True, policyPhase=phase,
                    sessionId='same', acceptedMaximumWidth=320 if phase == 'caps' else None,
                    acceptedMaximumHeight=None, acceptedMaximumBitrate=None,
                    fixedTrackId=fixed, maximumWidth=320 if phase == 'caps' else 0,
                    maximumHeight=100000 if phase == 'caps' else 0, peak=0,
                    hostFailureCount=0, hostStatus='playing'))
                frames.append(dict(elapsed=elapsed + .1, frames=1, width=320 if phase in ('caps', 'fixed') else 640))
        events = [dict(phase=phase, elapsed=i*10-.5, elapsedAfter=i*10-.1,
                       applied=True, itemChanged=True, sessionId='same')
                  for i, phase in enumerate(phases) if i]
        result = abr_accesslog.summarize_public_policy(rows, frames, events)
        self.assertEqual(result['phasesVerified'], phases)
        self.assertFalse(result['capabilityAccepted'])
        for kind in ['missing-phase', 'failed-command', 'changed-session', 'wrong-cap',
                     'wrong-fixed', 'high-under-cap', 'no-restored-high', 'no-frames', 'failure']:
            badrows, badframes, badevents = copy.deepcopy((rows, frames, events))
            if kind == 'missing-phase': badevents.pop()
            elif kind == 'failed-command': badevents[0]['applied'] = False
            elif kind == 'changed-session': badrows[-1]['sessionId'] = 'other'
            elif kind == 'wrong-cap': badrows[5]['acceptedMaximumWidth'] = None
            elif kind == 'wrong-fixed': badrows[13]['fixedTrackId'] = None
            elif kind == 'high-under-cap': badframes[6]['width'] = 640
            elif kind == 'no-restored-high':
                for frame in badframes[16:]: frame['width'] = 320
            elif kind == 'no-frames':
                for frame in badframes[8:12]: frame['frames'] = 0
            else: badrows[-1]['hostFailureCount'] = 1
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                abr_accesslog.summarize_public_policy(badrows, badframes, badevents)

''' + s[at:];p.write_text(s)
plan=Path('docs/superpowers/plans/2026-10-28-ios-public-policy.md')
plan.write_text('''# iOS public-host 真机清晰度矩阵实施与验收

基线7c4cf933；继续用户已授权的未完成项。沿用系统排障、测试驱动、集中验收；当前工作树直接实施，不发布。

目标：补齐原生typed public host在真实120秒素材下初始自动、320宽度上限、清除上限、固定320低档、恢复自动的媒体/策略观测。此轮不接入生产自动恢复，不把普通切换矩阵当作恢复竞争、物理屏幕或音画连续性验收。

实现选择：复用现有受限地址、制品身份、240秒采集和140秒原生期限；显式--public-policy-cycle只能用于managed DASH、120秒、无诊断恢复。四个命令按8/24/50/70秒发起，通过YlApplePlayerHost公开typed方法；采样来自host当前状态、accepted constraints、AVPlayer及实际纹理帧。每条命令单独记录开始/结束、item变化和session身份。新增失败关闭的采集校验，不因到片尾而忽略缺失阶段或无新帧。

- [ ] Python验证器先红后绿：缺阶段、命令失败、session变化、策略失守、缺新帧及恢复自动后无高档必须失败。
- [ ] 原生接入public host周期，canonical和iOS/macOS镜像同步；定向构建。
- [ ] 同一制品在原冻结配置及独立零延迟诊断配置各采集一轮；不改原配置/恢复门槛，失败保留。
- [ ] 最终受影响原生/工具矩阵、一次独立复审、原始证据与完整xcresult归档、更新台账并本地提交。

保留其余未完成项：原配置稳定自动恢复、旧候选与public host竞争、凭据竞争、新帧空档、物理路由与音画/字幕、多设备最低系统、DRM/Dolby授权。旧终末停顿不恢复待办。
''')
