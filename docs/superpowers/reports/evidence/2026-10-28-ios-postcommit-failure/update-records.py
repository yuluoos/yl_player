from pathlib import Path
import json,hashlib,subprocess
r=Path('/private/tmp/yl-postcommit-failure');sha=lambda b:hashlib.sha256(b).hexdigest()
for name,count in [('final-macos-contracts',189),('final-device-contracts',214)]:
 d=json.loads((r/(name+'-summary.json')).read_text());assert d['passedTests']==count and d['failedTests']==0 and d['skippedTests']==0
for name in ['arm-dart-ios','verified-dart-macos']:
 d=json.loads((r/(name+'-result.json')).read_text());assert d['exitCode']==0 and d['testsPassed'];assert '2 committed sessions, 2 failures' in (r/(name+'.log')).read_text()
report=Path('docs/superpowers/reports/2026-10-28-ios-postcommit-failure.md');s=(r/'report-draft.md').read_text().replace('FINAL_RESULTS','''最终同源码：iPhone原生 **214/214**、macOS原生 **189/189**，均0失败/0跳过，逐项核对唯一执行身份与预期全集（iPhone8类、macOS7类）。真实Dart集成合约在iPhone及macOS各 **1/1** 通过，两平台均观察到2个已提交会话、2次对应失败和10条源请求。iPhone使用USB及本轮ARM iproxy兼容入口，macOS使用标准flutter test；有“无法前置窗口”工具警告但实际测试执行并通过，不作为物理前台连续性证明。

26份源文件绑定最终候选，复审前快照单独保留；普通lib/main.dart入口已恢复后才构建/运行原生矩阵。Dart定向静态分析0问题；消费者46项中45通过、1历史focused evidence缺失跳过，镜像声明iOS851/macOS895及来源检查通过。网络工具未改，复用上一轮绑定的124项证据；生产、公共协议和Android未改，未声称本轮全量Flutter/Android验收。

完整4份原生xcresult保留：targeted编译失败、typed复审前定向1/1、最终macOS189/189与iPhone214/214。Dart事件时序失败、逐会话终点超时、各次启动失败和最终通过日志均完整保留。''')
report.write_text(s)
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());old='ios-load-lifecycle-20261028';key='ios-postcommit-failure-20261028';d['evidence'][key]=dict(kind='report',path=str(report),sha256=sha(report.read_bytes()))
for row in d['rows']:
 if old not in row['evidence']:continue
 if len(row['evidence'])>=20:row['evidence']=[key if x==old else x for x in row['evidence']]
 else:row['evidence'].append(key)
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':row['nextAction']='qualify-concurrent-dart-credential-races-other-commit-failures-high-output-original-auto-recovery-and-physical-output'
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
p=Path('docs/superpowers/plans/2026-10-28-ios-postcommit-failure.md');p.write_text(p.read_text().replace('- [ ]','- [x]')+'\n本轮完成：[统一验收报告](../reports/2026-10-28-ios-postcommit-failure.md)。原生iPhone214/macOS189；真实Dart合约双平台各1通过。整体ABR/物理连续性与外部资源项仍保留。\n')
previous=json.loads(subprocess.check_output(['git','show','90be00d1:docs/superpowers/reports/evidence/2026-10-28-ios-load-lifecycle/source-identity.json'],text=True));now=json.loads((r/'source-identity.json').read_text());network={p:h for p,h in now.items() if p.startswith('tool/playback_network/')};assert all(previous.get(p)==h for p,h in network.items());(r/'network-baseline-reuse.json').write_text(json.dumps(dict(baseline='90be00d1',unchangedFiles=network,priorTests=124,rerunThisRound=False),indent=2)+'\n')
print('report and ledger updated')
