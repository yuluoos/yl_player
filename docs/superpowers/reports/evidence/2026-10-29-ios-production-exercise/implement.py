from pathlib import Path
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text()
s=s.replace("    if not enabled: return False\n", "    required = getattr(args, 'require_production_install', False)\n    if type(required) is not bool or (required and (not enabled or command == 'load-prepared')):\n        raise ValueError('production installation requirement needs same-session production capture')\n    if not enabled: return False\n",1)
s=s.replace('def summarize_production_recovery(rows, frames):','def summarize_production_recovery(rows, frames, *, require_install=False):',1)
s=s.replace("    require(bool(rows) and bool(frames))\n    sessions = production_sessions(rows)","    require(type(require_install) is bool)\n    require(bool(rows) and bool(frames))\n    sessions = production_sessions(rows)",1)
s=s.replace("    for event in installed:\n        require(event.get('itemChanged')", "    require(not require_install or bool(installed))\n    for event in installed:\n        require(event.get('itemChanged')",1)
s=s.replace("        receipt['productionRecovery'] = production", "        receipt['productionRecovery'] = production\n        receipt['productionInstallRequired'] = getattr(args, 'require_production_install', False)",1)
s=s.replace("receipt['productionRecoveryObservation'] = summarize_production_recovery(rows, read_rows(out/'frame-samples.jsonl'))", "receipt['productionRecoveryObservation'] = summarize_production_recovery(rows, read_rows(out/'frame-samples.jsonl'),\n                require_install=receipt['productionInstallRequired'])",1)
s=s.replace("    p.add_argument('--production-recovery', action='store_true',", "    p.add_argument('--require-production-install', action='store_true', help='fail unless same-session production recovery actually installs; incompatible with new Load')\n    p.add_argument('--production-recovery', action='store_true',",1)
p.write_text(s)
Path('docs/superpowers/plans/2026-10-29-production-exercise.md').write_text('''# 生产自动恢复真实触发与竞争验收

基线cac7e4a8；按用户明确要求继续实施与集中验收，不发布。使用当前已附工作区；沿用原始失败及全部资源缺口，不改生产策略与门槛。

- [ ] 加显式require-production-install验收选项，拒绝自然升档/只有取消；新Load单独依原严格会话预算/候选取消检查，不计为同会话安装。先红后绿。
- [ ] 临时原生制品已清理，重新构建当前源码，冻结输入与制品；沿用既有停流/恢复诊断profile，不声称修复原配置。
- [ ] 同一制品正常恢复、预约后暂停、候选后暂停/Seek/Load五轮真机采集，全部纳入；核对真实生产事件、双窗口、500/1000ms退避、每源2次预算、PTS与新帧空档。失败不重写。
- [ ] 统一工具、消费者、相关原生合约、独立复审和归档校验，更新台账；物理画面/音画、最低设备与授权项目未有实测则保留不通过。

用户已确认准备完成后约15分钟保持前台、不锁屏或切换App/音频设备；自动签名授权沿用。新选项只收紧本轮路径覆盖，旧诊断默认仍可记录未触发，不提升整体能力。
''')
