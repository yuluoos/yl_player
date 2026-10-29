from pathlib import Path
import json,hashlib,subprocess
r=Path('/private/tmp/yl-resume-timeout');analysis=json.loads((r/'media-analysis.json').read_text());source=json.loads((r/'final-production-source.json').read_text());failed=json.loads((r/'original-failure-analysis.json').read_text())
lines=[]
for n,x in analysis['results'].items():
 boundaries=x['continuity']['replacementBoundaries'];gaps=', '.join(f"{b['publicationGapMs']:.3f}" for b in boundaries) or '无替换'
 installed=len([e for e in x['events'] if e['outcome']=='installed'])
 lines.append(f"| {n.removeprefix('reviewed-')} | {'通过' if x['passed'] else '失败'} | {x['finalPosition']:.6f} | {x['attempts']} / {installed} | {gaps} | {x['continuity']['maximumPublishedFrameGapMs']:.3f} |")
normal=[x for n,x in analysis['results'].items() if n.startswith('reviewed-normal')]
spans=', '.join(f"{x['finalHighSpanSeconds']:.3f}" if x['finalHighSpanSeconds'] is not None else '未确认' for x in normal)
text='''# 恢复定位无回调与最终制品长素材验收

基线 `afbb4365`，分支 `codex/abr-recovery`。承接[上一轮定位失败报告](2026-10-28-ios-recovery-landing.md)，实施于10月28日至29日。集中验收，不推送、合并或发布。

## 已确认修复与红绿证据

原生测试故意保留AVPlayer恢复定位回调不调用：暂停状态下pendingRuntimeResume一直存在、通用stall watchdog已取消，没有错误收敛。原始timeout-red结果保留。现在同源替换的定位操作以现有 `configuration.network.readTimeoutMs` 安排超时（默认15000ms，原配置边界0–60000ms不变），只有当前item/generation/定位UUID可报告 `source.seek_failed` 并退休输出，迟到成功或重复超时不能复活旧时间线。暂停不延长操作；公开Seek接管使用自己的UUID和等待上限。恢复定位期间避免通用首帧/停顿监视器抢先分类，成功落点后恢复原监视器；普通非恢复Seek不增加新期限。这是操作失败保护，不是新设或放宽帧连续性性能门槛。

独立复审发现初版新增的callbackBinding守卫过严：新Load提交前音频获取失败后，回滚会重绑旧会话订阅，但未退休旧item；唯一计时器因此失效，再度无限等待。rebind-red实测复现，最小修复移除timer的binding条件，保留item/generation/UUID，并且不重新计时。rebind回归断言原deadline仍只有1个、新订阅收到恰好一次错误、旧订阅不收错误、重复触发无效。该问题是本轮初版引入并在复审中消除，不能算旧基线缺陷。

新增3项原生合约涵盖真实100ms调度下播放/暂停及公开Seek接管的无回调、成功/失败/迟到回调、旧timeout跨Seek/再次替换/Stop/deactivate/dispose/重绑、暂停不延期，以及配置边界和普通Seek隔离。红灯、初版绿灯/初版完整矩阵、重绑红灯和修正后定向5/5全部独立保留。使用可控回调的故障注入不能证明自然无回调的发生率或系统根因。

## 同一最终制品的7轮真机采集

全部使用最终冻结源码与同一二进制指纹，原生产触发条件、双窗口/请求数/带宽门槛、2次预算、500/1000ms退避、候选准备2秒、票据5秒、120秒素材及140/240秒期限均不变。

| 场景 | 严格结果 | EOF位置秒 | 最终预算 / 自动安装 | item边界新帧空档ms | 全程最大发布帧空档ms |
| --- | --- | --- | --- | --- | --- |
'''+ '\n'.join(lines)+f'''

总计{analysis['passedRuns']}/{analysis['totalRuns']}轮通过。三轮正常恢复对照为{analysis['normalRecoveryPassed']}/3，每轮恢复后至EOF的高档发布持续跨度分别{spans}秒；全部轮次计入。原配置与恢复对照采用既有不同profile，对照同时改变降速/停流、恢复时点、恢复上限及请求延迟；它不能证明原配置已恢复，也不能将差异单独归因为延迟。

原配置严格失败原样保留：native XCTest退出0只说明探针完成，production receipt仍passed=false。真实帧320→640→320，最终{failed['finalWidth']}，EOF {failed['finalPosition']:.6f}秒；9个完成窗口按Δbytes×8/Δtransfer复算为{failed['windowBitrateMin']:.3f}–{failed['windowBitrateMax']:.3f}bps，均低于原955000bps门槛，窗口请求数足够，预约/票据/尝试均0。没有后台/音频路由干扰，不能删除此失败、放宽带宽条件或用对照通过追认原配置。

暂停/跳转竞争要求取消第一次候选、预算不退款并在第二次退避后恢复；跳转实际首帧PTS沿用目标±50ms检查。新Load同请求标签仍是新会话，返回预算0，不能计为同会话自动恢复。完整命令事件、帧PTS、访问日志、代理边界和策略重算见归档。

表中item局部空档与全程最大空档分别报告。主动暂停、Seek、Load的时间线变化不能冒充自动替换连续性；真实复制/发布帧记录也不等于校准后的物理屏幕/声音同步。所有continuityAccepted、physicalOutputVerified、audioSynchronizationVerified和capabilityAccepted保持false。

## 统一验收与台账

修正后的完整受影响矩阵重新执行：iPhone 16 / iOS 27.2为243/243，macOS为218/218，均0失败0跳过；按唯一用例集合核对，覆盖DASH、会话、发布、网络、MP4/MOV、HLS等路径。网络工具131通过；消费者45通过、1因本地历史focused evidence缺失跳过；当前/历史目标及历史源一致性通过。408个冻结源码/测试/采集工具指纹匹配，同制品7轮全部纳入校验。原生QoS/main-thread及构建警告完整保留，绿灯不代表零警告。Dart/Pigeon未改，历史Dart证据只引用，不冒充本轮执行。

生产源码哈希 `{source['sha256']}`。发布台账源码绑定更新，102行implementation/verification/acceptance状态保持不变，CAP-ABR/iOS仍partial/not_run；sourceMatches=true、releaseReady=false。结构及15项台账回归通过，两项--require-ready继续退出1。独立综合复审与针对重绑问题的补审记录保留在[完整证据](evidence/2026-10-29-ios-resume-timeout/README.md)。

## 保留未完成项

- 原配置长素材仍未恢复高档，需要进一步区分实际带宽、传输开销及AVPlayer选档行为；现有证据不支持安全降低触发门槛。
- 更多异步提交后故障、命令/生命周期交错、多设备/最低系统及真实生产网络稳定性尚未穷尽；本机三轮对照不代表普遍稳定性。
- 缺校准物理音画采集、更多设备及授权资源的项目继续保留，不能以合约绿灯或发布帧时间戳替代。

旧终末停顿不重新列为待办。原始失败不覆盖，历史25组6419清单项与基线核对不变；当前归档保留完整xcresult、阶段源码指纹、同制品证明及逐字节来源记录。工程修复与受控对照已验证，整体ABR/物理连续性验收仍未完成。
'''
p=Path('docs/superpowers/reports/2026-10-29-ios-resume-timeout.md');p.write_text(text)
p=Path('tool/release_readiness/inventory.json');j=json.loads(p.read_text());j['source']=source;key='ios-resume-timeout-20261029';report='docs/superpowers/reports/2026-10-29-ios-resume-timeout.md';j['evidence'][key]=dict(kind='report',path=report,sha256=hashlib.sha256(Path(report).read_bytes()).hexdigest())
for row in j['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[key if x=='ios-recovery-landing-20261028' else x for x in row['evidence']]
  row['nextAction']='qualify-original-profile-high-recovery-other-postcommit-races-multidevice-and-physical-av-continuity'
p.write_text(json.dumps(j,indent=2,ensure_ascii=False)+'\n')
p=Path('docs/superpowers/plans/2026-10-28-ios-resume-timeout.md');s=p.read_text().replace('- [ ]','- [x]');s+='\n本轮执行完成，原配置长素材严格失败保留，其他异步/多设备与物理音画仍未验收。详见2026-10-29报告；不发布。\n';p.write_text(s)
