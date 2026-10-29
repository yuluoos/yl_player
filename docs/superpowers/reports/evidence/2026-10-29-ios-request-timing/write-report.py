from pathlib import Path
import json
r=Path('/private/tmp/yl-request-timing');a=json.loads((r/'analysis.json').read_text());source=json.loads((r/'final-production-source.json').read_text())['sha256']
s='''# iOS 请求级上游与回环边界验收

基线91ecf8f9，分支codex/abr-recovery。承接[原配置带宽单因素排查](2026-10-29-ios-original-bandwidth.md)，集中验收，不推送、合并或发布。

## 实现与已确认修复

新增DEBUG显式启用的请求边界：同一设备单调时钟下的接入、响应头回调、首尾body回调、发送提交/完成、上游完成和终末记录；字节、发送次数、等待总和/最大值及完成/取消/失败均独立保存。默认无observer，不创建trace；Release不编入这套观测。每个代理任务最多投递一次终末记录，不保存全局事件历史；测试文件上限10000条/16MiB，超限或写入失败使探针失败。

用随机代理标识、数字请求序号、测试服务器响应编号关联，不记录URL、凭据、任意头内容或音频设备名称。实际控制发现3条响应前取消，根本没有响应头回调，因而新增仅显式采集时发送的随机UUID X-Yl-Trace-Id。fixture只记录单个合法UUID，reader同时有请求/响应标识时交叉核对，冲突拒绝。它是调试关联元数据，不参与鉴权、选档、恢复或请求路由。

原生真实请求红灯证明旧实现无边界事件；增加真实取消、一次封存、迟到回调、隐私字段及收尾并发合约。独立复审发现并修复3项P2，全部保留红绿证据：

- 合法取消时，后一个body发送尚未完成，lastSend可晚于已经完成的header的lastSendComplete；reader现在只在所有发送完成时要求最终发送顺序，取消不能误报成功或被错误拒绝。
- 缺少请求记录原先只令fullyCorrelated=false，未阻止成功回执。现在保留partial summary并加入明确错误；原始回执不改写，旧版本仍明确区分。
- task移除早于终末写入会漏掉chunk尾或迟到observer。独立活跃trace表持续持有到observer返回，close/cancelAll都能封存；capture注册与stop同锁，注册enter、observer完成后leave。探针关文件前必须在2秒内drain，否则XCTest失败。真实阻塞observer的回归证明sealed不等于delivered：旧实现已无task但找不到trace，新实现保留1条，短等待失败，放行observer后排空成功，stop后拒绝新注册。不在trace锁内调用observer，不让finish等待自身重入。

## 全部采集保留，按制品阶段分别绑定

前三轮为复审前制品，后两轮为修复后的最终制品；每阶段内部二进制哈希一致，不混为一个最终制品重复矩阵。所有原始receipt、失败、取消、完整xcresult及阶段源码指纹保留。

| 阶段/场景 | 原回执 / 最终重算 | EOF秒 / 宽度 | 自动次数 | 恢复后持续高档秒 | 最大新帧发布空档ms |
| --- | --- | --- | --- | --- | --- |
'''
for name,x in a['results'].items():
 s+='| '+name+' | '+('通过' if x['originalReceiptPassed'] else '失败')+' / '+('通过' if x['finalReassessmentPassed'] else '失败')+f" | {x['position']:.6f} / {x['finalWidth']} | {x['attempts']} | "+(f"{x['highTailSeconds']:.3f}" if x['highTailSeconds'] is not None else '未恢复')+f" | {x['continuity']['maximumPublishedFrameGapMs']:.3f} |\n"
s+='''
复审前两轮原配置由AVPlayer自然320→640→320→640，attempts=0、triggerExercised=false，不能算自动替换修复，也不能覆盖历史失败。复审前控制真实自动安装1次，但376条代理记录中3条响应前取消未能关联，旧回执为true，最终严格重算必须为失败；不能删除这轮或改写旧receipt。两轮自然升档还分别存在约1.39/1.37秒发布帧空档，物理连续性不因此通过。

最终原配置再次失败：120.029516秒EOF仍320，预约/票据/尝试0；9个完整窗口0.680–0.883Mbps均小于固定0.955Mbps门槛，请求数充分。338条代理请求（336完成、2取消）全部关联，无丢失或未关联请求；无host failure、后台/音频切换记录。不同阶段出现自然恢复/不恢复，说明原配置行为仍有波动，不能归因于本轮日志代码已修复选档。

## 请求边界定位结果

最终原配置的恢复阶段（服务端25秒后且整请求位于该阶段）共有243条完成请求，写出3117922字节。对相同请求集合分别计算：

- 服务端处理区间总和21.857秒；上游接入至完成回调总和35.889秒，差14.032秒。
- 接入至响应头回调总和25.510秒，首尾body回调区间总和10.210秒。
- 回环发送contentProcessed等待总和0.426秒，单次最大1.642ms。
- 按同一请求集合的上游完整生命周期估算有效吞吐约0.695Mbps；服务端写出区间约1.141Mbps。它们是诊断值，不能替代原策略窗口。

这把排查重点缩小到上游请求生命周期：已测到的代码等待回环发送回调时间不足以解释主要差额。响应等待包含连接、传输、服务端延迟及URLSession回调调度，不能从这里直接断言是纯RTT、Wi-Fi或某个系统缺陷；还需URLSession事务级连接/请求/响应指标细分。服务端与设备只比较各自区间长度，不相减绝对时间；等待总和可能重叠，不与wall time直接相加。当前owned fixture无HTTP重定向，任务级记录不外推为重定向各跳的事务测量。

[Apple定义](https://developer.apple.com/documentation/network/nwconnection/sendcompletion)中的contentProcessed只是网络栈处理已提交内容，并非客户端收完、解码、屏幕显示或音画同步。因而未删除背压、未强行升档、未扣掉测得开销来抬高带宽，也未放宽任何恢复或连续性门槛。

## 统一验收及台账

最终macOS222/iPhone247用例全部通过，0失败0跳过，唯一用例集合与最终源码核对；工具148通过，消费者45通过1项历史focused evidence缺失跳过，当前/历史目标和源一致性检查通过。412份最终源码/测试/工具指纹冻结；复审前412份另存，10份差异明确记录。中间红灯、初版完整矩阵及定向补审均保留，不冒充最终矩阵。原生构建与QoS等警告仍在原始日志中，成功不代表零警告。Dart/Pigeon/Android实现未改，历史证据不算本轮重跑。

'''
s+=f'生产源码快照哈希 `{source}`，变化仅YlHlsMediaProxy.swift的调试采集支持；生产恢复策略、8秒双窗口、955000bps、预算/退避和候选期限不变。完整证据见[归档](evidence/2026-10-29-ios-request-timing/README.md)。\n'
s+='''
## 保留未完成项

- 原配置高档恢复仍未通过：需要继续细分上游连接/网络/回调调度开销，证实安全优化后再修改生产行为。不能用自然恢复的两轮或多变量控制追认失败。
- 更多生产网络、设备/最低系统、异步提交后故障与命令竞争、重复稳定性仍未穷尽；最终每种场景只有一轮。
- 物理音画采集未校准，缺设备与授权资源项继续保留；发布帧时间戳不替代真实屏幕/声音连续性。

旧终末停顿不重新列为待办。本轮处理的是日志收尾所有权问题。整体CAP-ABR与发布保持未就绪，不发布。
'''
Path('docs/superpowers/reports/2026-10-29-ios-request-timing.md').write_text(s)
