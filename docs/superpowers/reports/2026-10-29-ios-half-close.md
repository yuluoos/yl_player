# iOS 快取消的 EOF 内部路径与半关闭缺陷

基线2e3e2793，承接[默认池取消记录](2026-10-29-ios-cancel-byte-boundaries.md)。不发布、不放宽门槛，原失败及设备/授权缺口保留。

## 定位结果

代码可确定的本地链为 receiveRequest（完整请求同时收到EOF）或 monitorDisconnect（后续EOF）→close(cancelCause:2)→移除TaskRecord→URLSessionDataTask.cancel()。Foundation终态及metrics随后单独收尾。因此cause2只记录代理观察到读方向EOF，不证明客户端关闭了读方向或放弃响应，也不能直接归因于AVPlayer内部策略。trace.outcome=1和taskOutcome分别保留，不混为一个结果。

[RFC 9112 §9.6](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.6)说明客户端TCP半关闭不表示它不再需要响应。本轮真实NWConnection只用finalMessage关闭写端，同时继续读取；同一请求直连自有HTTP服务器可以读取正文，经代理则进入上述取消路径。该对照确认代理的半关闭语义缺陷；历史AVPlayer是否采取同样操作尚无证据，不能关闭历史根因。

## 实施、测试和边界

新增原生开放缺陷特性对照及canonical镜像，注册数880/924。测试绿色表示准确复现当前行为；halfCloseSupportAccepted、historicalCauseProven、capabilityAccepted均false，不能把复现当修复验收。

初版运行选定原生矩阵iPhone253/253、macOS228/228通过（非全部880/924注册用例）。独立复审发现P2：即时上游响应可能抢在EOF前封存成功，导致强制取消断言不稳定。已仅在代理路径持有上游响应、在循环defer释放；直连不持有。门闩修正后各平台只重跑该方法1/1，其他方法及生产代码没有变化，复用修正前选定矩阵，其源码身份source-before-gate.json与最终source-identity.json分开保存。修正前原始结果完整保留。附注：测试内旧字节注释仍描述一般竞争；实际最终代理对照明确由门闩隔离响应，该注释不作为证据或验收条件。

工具200通过；消费者45通过、1既有历史focused证据跳过。本轮没有新增长素材采集，上一轮2/2只是历史记录，不充作本轮执行。生产取消/恢复代码未改，不据该结果宣称高档恢复或物理连续性提升。

| 执行 | 直连正文完整 | 代理收到字节 | 代理EOF原因 | downstream outcome / task outcome | 事务数 |
| --- | --- | --- | --- | --- | --- |
| ios-final | True | 0 | 2 | 1/1 | 1 |
| macos-final | True | 0 | 2 | 1/1 | 0 |
| ios-confirm | True | 0 | 2 | 1/1 | 0 |
| macos-confirm | True | 0 | 2 | 1/1 | 0 |

原始附件包含全部计数与时间状态。空事务没有可用字节计数，不能填零；请求取消发生在记录发送之前可导致服务器没有对应请求，但历史实际发包和AVPlayer决策仍未证明。此前受控双事务由服务器解析同一task两次，历史样本仅一次接入，两者仍不能等同；没有为旧v2补造字节或响应日期。

## 安全修复缺口与发布台账

本轮确认了缺陷，但没有实施生产行为修复。直接忽略EOF会同时改变完整断开后的取消回收，可能继续下载失效资源；现有EOF取消合约与完整HTTP半关闭语义存在冲突。后续需设计明确取消权威及有界回收，验证完整断开、半关闭、无响应上游、预算与生命周期竞争后再改变策略，不能为制造服务器关联强迫取消请求发送。本轮只修复了测试竞态并补齐可复核的定位证据。

历史快取消、历史一次接入双事务缺响应继续开放。物理显示/音画同步、最低系统/更多设备、授权媒体、实际网络稳定性、预算耗尽后自然高档及其他生命周期竞争、历史macOS就绪超时缺口继续保留；旧终末停顿待办不重新加入。

[完整证据](evidence/2026-10-29-ios-half-close/README.md)含4个完整xcresult、原始附件、修正前后源码身份、复审与台账检查。43组历史证据与基线逐条核对；102行implementation/verification/acceptance不升级，旧全局证据保留，CAP-ABR/iOS最近引用轮替并链向旧报告。生产指纹不变；sourceMatches=true、releaseReady=false，require-ready保持退出1。未推送、未合并、未发布。
