# 独立综合复审：回环错误来源与预算耗尽恢复

复审日期：2026-10-29。基线：`6b4682000762f449e13ca95e531a56ddc0ceb3f4`，对象为本轮未提交 diff。按 consolidated-acceptance / requesting-code-review 执行一次独立综合复审，未修改产品或测试代码，未运行新测试或启动设备采集。只写本复审文件。

结论：**未发现本轮新增的 P0/P1/P2 阻断问题；发现 1 项 P3 注释措辞问题，deferred minor。诊断缺口已得到本轮证据支持，但预算耗尽后的自然高档恢复仍失败，不能标记恢复能力、物理连续性或发布验收完成。**

## 范围与证据身份

直接审阅计划、报告、生产与消费者 diff，原始 `media/{budget-throttle,normal}/` 请求、代理、策略、帧及回执记录，原生结果汇总、用例身份、RST/双事务附件、红绿日志、历史与台账材料。以下路径均相对于 `/private/tmp/yl-loopback-error-source`，除非注明仓库路径。

复审独立读取并核对：`source-identity.json` 的 438 项当前输入无哈希漂移；`binary-identity.json` 的 307 项现存 iPhone 制品无漂移，两轮 receipt 的 binaryHashes 均与该清单精确一致；`media-raw-identity.json` 的 24 项原始媒体文件无漂移。两个平台 case-identities 的 expected/observed 精确相等，分别 256/231，无 skipped。

本结论针对上述当前源码和原始证据。复审期间归档仍在纳入本文件，**没有把尚未最终封存的归档及最终 SHA256SUMS 视为已经独立验过的最终交付物**；完整归档校验由收尾流程执行。本复审没有运行会写入证据或重跑测试的 verify.py。

## Findings

### P3（deferred minor）：source 0 的源码注释过宽

位置：`packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift:1019`，`v7 sources: 0 not an error`。

`finish(outcome: 2)` 的发送失败也写 source/domain/code 为 0，因此此处应更精确地表述为 `0 no recorded cancellation error`，不能将 0 当作整个请求没有错误。原始预算轮有 2 条、正常轮有 3 条 `outcome=2, cancelSource=0`，直接证实该区别。报告及 error-analysis.json 已正确解释，消费者保留 outcome，没有错误判定或门槛变化。为维持已测冻结输入与制品的严格绑定，本轮记为 deferred minor；不阻断本次诊断结论。

没有其他新增可执行阻断 finding。

## 代码、契约与回收审查

- 三个生产入口映射准确：state.failed→1，请求头 receive error→2，已接纳请求 monitor receive error→3；分别透传对应 NWError。所有错误入口继续调用原 close，任务取消、连接取消、独立 deadline 的释放顺序与基线一致。未改恢复政策、预约次数或播放器行为。
- trace 的锁及 `!sealed && !downstreamFinished` 冻结首个终止记录，后到 finish 不覆盖来源/域/码。普通 body/send 更新在 downstreamFinished 后停止；metrics 仍允许在任务收尾前更新，记录交付继续等待 taskPending 清除。这里证明的是 trace 首次记录，而非所有回调的真实物理先后或 AVPlayer 意图。
- 新映射用例覆盖 POSIX、DNS、TLS、未知域，负数码和晚到错误/body/task 完成。晚 send 忽略由既有 `testProxyRequestTimingSealsCancellationAndIgnoresLateSendCompletion` 验证；不得单独把新用例说成实际调用了 sent。两项均包含在本轮两平台执行身份中。
- 真实 SO_LINGER RST 用例检查 source∈{1,3}，不硬编码系统回调先后，且检查 task/connection/deadline 归零。两平台附件此次实际均为 source3/domain1/code54。半关闭完整正文、排队半关闭及 silent closed/non-reading 客户端 deadline 回收用例也在已通过矩阵中。没有把错误 receive 的 source2 映射用例当成接纳前请求的真实日志覆盖：trace 仅在 handle 接纳后创建，接纳前错误没有请求 trace。
- 新字段是有界枚举和 NWError 原始数值，没有写入 localizedDescription、URL、凭据、IP 或原始日期。资源关联沿用每代理 HMAC token；新增字段不扩大身份数据输出。
- Python 消费者要求 v7 三字段齐全，拒绝 bool/float/越界码、非法枚举及与 cancelCause 矛盾的组合；有符号码独立校验，不被非负时间校验误拒。v1–6 禁止携带新字段，输出 null，不依据历史 cancelCause3 伪造来源。成功事务完整性、关联及 metrics 版本要求保留。两个 CLI 和三份测试来源同步至 v7；未来版本拒绝改为 8 是协议升级所需，并非放宽未知版本。

## 已有执行证据复用

- native-red：退出 65，旧实现真实取消用例 1 失败，含版本 6≠7 和缺字段断言；未被覆盖。tools-red 的 23 项中 2 个 ValueError，以及首次 green 的旧“版本7应拒绝”失败日志均仍在。
- 最终 iOS/iPhone16/iOS27.2 256/256，macOS 231/231，退出 0，无失败/跳过。工具日志 203 项 OK；独立消费者 46 项中 45 通过、1 个既有历史 focused 证据缺失 skip。注册 883/927 是清单数量，不当成本轮执行数量。原生警告及诊断采集不完整记录没有被抹去。
- 原生强制首次上游连接关闭的双事务附件仍显示 2 事务、首事务日期缺失、第二事务完成。这只证明受控诱因，不解释历史成功双事务。旧六轮 byte replay 的原始失败继续保留，不用新单事务采集关闭旧问题。

## 原始媒体证据与归因边界

预算轮：376 条代理记录，372 complete、2 cancelled、2 sendFailed；最后样本 position=120.026411572、width=320、automaticAttempts=2。回执 passed=false、errors=["ValueError"]，重算同样失败。预算专项保留 2 次预约/1 次安装、未退款、无第三次预约，以及两段合格带宽窗口约 2.797/2.609Mbps。预算专项通过不替代最终 640 的严格恢复门槛。

直接关联 server request229 与 proxy request50：correlationID 一致，资源为 network-period-16/chunk-1-00004.m4s；proxy source1/domain1/code54、cancelCause3、bodyBytes=sentBodyBytes=65536。server bodyBytesWritten=66560，完整范围终点68293，outcome=client_io_error。代理接纳至下游终止约 2.013931 秒；服务器本地时钟约 2.110548 秒。后续高档请求为 0，90秒后原始宽度均为320。此记录排除了“此次首记录是25秒代理deadline或cancelAll”，但**不能推出 AVPlayer 已确认的2秒私有timeout、penalty或不再重试的内部原因**。

服务器等待共享速率锁约0.496552秒、持锁1.596543秒，实际sleep1.592798秒；50000B/s控制是共享速率，不能把该轮称为没有错误的纯带宽实验，也不能直接以单请求有效吞吐判定生产代理缺陷。服务器写入、代理接收、代理发送及播放器接收是不同事实；设备 uptime 与服务器时钟不相减。

正常轮：407 条代理记录，397 complete、7 cancelled、3 sendFailed；两次真实安装，最后 position=120.027522146、width=640，原回执与重算通过，第二次高档后稳定尾段约34.148秒。预算轮同时使用公开pause-resume与不同profile，两轮并非单变量实验，横向差异不能证明断开/重试机制。

预算轮替换边界新帧间隔154.166ms，全程最大2071.900ms；正常轮边界85.625/137.191ms，全程最大323.077ms。原始 published frames/代际边界支持这些诊断观测，不能代表物理音画测量或已接受连续性。两轮 `continuityAccepted`、`audioSynchronizationVerified`、`physicalOutputVerified`、`capabilityAccepted` 仍为 false。

## 台账、历史与结论限制

独立读取基线与当前 inventory：102 行 implementation/verification/acceptance 无状态漂移。独立逐项核对 48 个历史 SHA256SUMS 与基线6b468200完全一致，并重新读取10118个所指文件核对哈希，零差异。readiness 结果记录结构检查退出0、require-ready退出1，15项台账回归通过；ledger 为 sourceMatches=true、releaseReady=false。

本轮足以支持“新诊断将该次最后高档失败定位到首记录 state.failed/POSIX54，并确认预算耗尽后仍未自然恢复高档”。它不构成恢复行为修复或全项目验收：预算耗尽后的自然恢复、长期稳定性、更多生命周期竞争、历史双事务、历史macOS就绪超时、设备/最低系统/实际网络/授权素材及物理音画缺口继续保留。没有建议增加预算、降低门槛、发布或恢复用户已删除的旧终末停顿待办。
