# 半关闭修复独立代码复审

复审基线：28ddf707。工作区生产 YlHlsMediaProxy.swift SHA-256：24d90e6814c58851f4185582a1606c597e029372fc095ce259ed7d5f6e523993。只读源码与现有证据，未运行设备/模拟器测试。

## 结论

本次生产差异未发现必须修复的并发、所有权、计时器清理或半关闭语义缺陷。静态复审可通过；完整验收仍须最终原生矩阵与两轮媒体证据，不将此前单测红绿视为媒体能力通过。

## 核查

- 完整 GET/HEAD 头部后的 FIN 不再取消响应；header 不完整时 EOF 仍关闭，明确 Network 错误仍关闭，发送错误/所有者取消路径保留。
- 每 accept 在与连接所有权相同的锁内登记 timer，且在锁内 resume。timer 在 utility 队列工作，因此无需等待 proxy 网络回调串行队列；timer handler 对 self/connection 均为 weak，不引入持有环。
- close 在同一锁内移除 connection、deadline、task 与 record；cancelAll 同样先屏蔽 admission，再清空/取消 timer，之后使 URLSession 失效并取消连接。任务创建/resume 的 admission fence 未修改。计时器与完成/取消并发时只能重复幂等 close；handler 的 strong local connection 防止 ObjectIdentifier 重用误伤新连接。
- 正常定长响应最后一笔发送完成及 chunk tail 回调仍经 close；deadline 在 URLSession record 已移除、但 chunk tail/send completion 尚未回来时仍保留，有界保护覆盖该间隙。
- 新 lifetime 先分别转换 TimeInterval 再求和，不产生新的 Int64 加法溢出。map 配置各夹到 0...60000，所以常规生产范围最大约 120 秒。native 直接构造极值仍可能触发 init 原有 sessionConfiguration 中 Int64 相加溢出；这是基线既有问题，不属于此差异引入的缺陷，也不能宣称本修复解决了所有配置极值。
- 总期限从 accept 起计入头部、排队和发送时间，较原有仅上游资源超时更严格；默认 25 秒，符合已批准计划。没有改变媒体逐请求关联、成功事务完整性、ABR/预算/连续性门槛或诊断 late-metrics 生命周期。

## 测试/证据观察

- 已读 red/green summary：半关闭回归旧生产失败（cancelCause 2 != 0），新生产 1/1 通过。
- 初轮 macOS 227/228 通过；唯一失败为 mode 2 创建而未等待 upstream entered expectation。当前源码已改 mode 2 不创建该 expectation；需最终矩阵确认，初轮失败记录必须保留。
- nonreader mode 3 当前断言只证明限定时间内连接/task/deadline 归零。8 MiB 可能在个别平台被缓冲并正常完成，因此单靠该断言不能证明 stalled-send deadline 分支。建议最终附件确认 outcome/cancelCause 与 pending-send/backpressure；若要作为长期分支回归测试，应明确断言 deadline 触发且此前存在未完成发送。mode 0 已用 Foundation 30 秒、proxy 500 ms 配置单独覆盖独立 deadline。
- 所有者取消仍有断言，完整断开允许明确错误或最终 deadline 回收符合 FIN 无法确定读侧兴趣的实际语义。删除旧“write EOF 一定取消、永不访问上游”断言是修正错误契约；不能由此放宽真实媒体完整响应与事务证据门槛。
- git diff --check 无输出。

后续：收到最终矩阵和两轮媒体制品后补充同次证据复审；本文件当前不是完整发布批准。
