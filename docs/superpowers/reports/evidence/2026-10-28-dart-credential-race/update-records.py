from pathlib import Path
import json,hashlib,re
r=Path('/private/tmp/yl-dart-credential-race');sha=lambda b:hashlib.sha256(b).hexdigest()
for name in ['final-ios','final-macos','final-unit','final-analyze','final-entry-analyze']:
 assert json.loads((r/(name+'-result.json')).read_text())['exitCode']==0,name
assert re.search(r'\+29: All tests passed!',(r/'final-unit.log').read_text())
report=Path('docs/superpowers/reports/2026-10-28-dart-credential-race.md');s=(r/'report-draft.md').read_text().replace('FINAL_RESULTS','''最终统一入口：iPhone **3/3**、macOS **3/3** 通过，均含顺序失败、MPD竞争、媒体竞争，0失败/0跳过。两平台日志中的两组并发时序与凭据布尔记录已抽取并核验；首次凭据的精确合成值在原测试断言中核对，日志不记录凭据内容。相关Dart控制器/Apple桥接单元 **29/29** 通过，两个新增入口定向静态分析均0问题。完成后恢复普通lib/main.dart入口。

iPhone使用本轮确认的USB连接及上轮已验证的进程级ARM iproxy兼容包装；只替换不兼容的缓存工具路径，不修改SDK或生产代码，不跳过测试。启动阶段仍有60秒VM发现提示，随后真实连接、执行三项并通过；保留完整日志，不把启动提示当作产品媒体停顿。''');report.write_text(s)
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());old='ios-postcommit-failure-20261028';key='dart-credential-race-20261028';d['evidence'][key]=dict(kind='report',path=str(report),sha256=sha(report.read_bytes()))
for row in d['rows']:
 if old not in row['evidence']:continue
 if len(row['evidence'])>=20:row['evidence']=[key if x==old else x for x in row['evidence']]
 else:row['evidence'].append(key)
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':row['nextAction']='qualify-other-commit-failures-high-output-original-auto-recovery-and-physical-output'
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
p=Path('docs/superpowers/plans/2026-10-28-dart-credential-race.md');p.write_text(p.read_text().replace('- [ ]','- [x]')+'\n完成记录：[统一验收报告](../reports/2026-10-28-dart-credential-race.md)。真实集成双平台各3项通过，Dart单元29项通过；未改生产实现。\n')
unitFiles=['packages/yl_player/test/apple_player_controller_test.dart','packages/yl_player/test/player_controller_test.dart','packages/yl_player/lib/src/player_controller.dart']
(r/'unit-source-binding.json').write_text(json.dumps(dict(commandTargets=unitFiles[:2],sha256={p:sha(Path(p).read_bytes()) for p in unitFiles},passed=29,contextSnapshotNote='final-unit-source.dart records the integration work context; these two Dart unit files were the actual command targets.'),indent=2)+'\n')
print('updated report and ledger')
