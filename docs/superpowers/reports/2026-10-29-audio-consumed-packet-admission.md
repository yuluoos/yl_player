# 音频已消费输入的容量失败修复（2026-10-29）

基线 `16869125d2eb42969b63e494f42432e1be8b51b9`，分支 `codex/audio-consumed-packet-admission`。本轮优先修复 P03/P08 的实际播放器准入缺口；不改 DASH/ABR、另一聊天工作树或 iOS 恢复逻辑，不推送、不发布。实施验收时尚未提交；现已本地合并并清理分支，见[合并记录](2026-10-29-audio-admission-merge.md)。

## 问题与修复

普通音频路径先检查估算容量，再调用有状态 converter。转换后的 PCM 若超过实际剩余时长/字节限额，旧代码返回 wouldExceed；YlAudioPipeline 将已消费包留作 pending，稍后再次提交。这会丢弃本次 PCM 并重复推进解码器，不能作为正常背压处理。真实 AAC-LC 静音包在 durationUs=1 的错误短报时长下复现 wouldExceedDuration；不是只有模拟 converter 的推测，也不代表所有正常素材均有该故障。

修复将普通路径转换后超限改为现有安全错误 policy.unsupported，与 terminal 路径一致。没有增加公共错误类型、额外待播缓冲或资源限额；转换前背压继续等待容量后重试。pipeline 已有错误传播路径立即报告失败，不再保留或重放该包；拒绝的 PCM 释放，reset 后新代可以重新调度。该修复不尝试恢复已经消费的损坏/短报输入。

## 定向验证

首批新增共享原生测试 4 项：字节/时长超限与 payload 释放/reset；真实系统 AAC 转换；pipeline 不保留重放；转换前背压可恢复。旧实现 1 通过、3 失败；修复后连同既有真实 Opus/Vorbis 所有权及取消测试 6/6 通过。共享测试镜像 iOS/macOS 保持一致，发现清单增加对应 4 项。

初次 Flutter 配置误在仓库根执行，缺 lib/main.dart；从 example 目录执行成功。首次 xcresulttool 读取被沙箱阻止写 TestReport 缓存，获准后读取同一原始结果；这些环境失败保留，不计作测试通过或产品失败。

## 集中验收

首轮完整 macOS 实际执行 916 项：915 通过、1 个 DTS 实际音画/seek 失败，0 跳过；运行身份与冻结的全部用例清单匹配。原始失败不抹去。新的明确失败暴露出 DTS 时长估算只相信容器值：现有48 kHz素材容器包时长10000us，实际512帧PCM为10666us。新增真实 DTS 回归同时检查0、1、原始时长和Int64.max声明，旧估算测试失败。

最初采用8192帧时长上界的候选在三类相关测试中30通过、1失败：既有100ms DTS窗口被拒绝。独立复审另发现32kHz/0.25倍速下256000us预留超过250000us有效窗口，空队列仍永久背压。两项均作为真实回归修复，保留失败记录；未放宽用户限额或改写原100ms验收预期。

最终 DTS 实现只在完整、长度精确匹配、无embedded extension的core包上读取块数和core采样率，并向上取整。支持16/14-bit BE/LE，最多读取14字节；字节预留仍为既有8192帧。截断、未知同步字、非法采样率、附加EXSS或嵌入扩展回落decoder cap。采用 [FFmpeg DCA framing](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/dca.c) 和 [parser时间关系](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/dca_parser.c)，不将core前缀当作独立HD/XLL输出的证明。renderer 将单包估算与有效总时长上限比较，无法通过排空队列解决的超限在转换前明确失败；正常剩余空间不足仍背压。比较与capacityResult共用同一锁内倍速/严格预算规则。

最终共享新增6项（实际共享类8项）。真实DTS测试保持容器0、1、10000和Int64.max时长控制，并把真实core重打包四种格式、修改频率字段，检验32kHz/0.25倍速和16kHz/0.5倍速的实际解码与调度；另测不可满足单包预留不转换、不重试。保守候选下新增两项均RED。最终四类相关矩阵142/142通过、0失败、0跳过，xcodebuild退出0；原100ms窗口、DTS音画/seek及全部新增用例通过。实际身份与最终六文件快照逐项一致。iOS Simulator arm64 的 config-only 与 build-for-testing 均退出0，未启动设备或执行iOS测试；Swift并发和XCTest最低链接版本警告保留。这不是iOS运行、真机或最低系统资格通过。

首轮独立复审无可操作发现，后续复审指出上述P2并在最终代码复核确认实现层解决；独立复审核验最终142项身份、全部通过结果、六份源码哈希以及iOS编译收据后关闭P2，无剩余可操作发现。复审未直接验证“已有队列超限+ledger token释放”和“pending首次背压后转换超限”的组合，静态路径正确；接受其覆盖边界，不宣称已实跑这些组合。

当前发现清单原始方法数iOS881/macOS925；条件编译解析的macOS运行身份918。数字不等同本轮全部重新执行。首轮全套916项与最终142项按身份核验，复用未受影响776项通过记录，共覆盖现有918个运行身份；这不是一次最终候选918项全套运行。复用范围不涉及DTS估算，其他managed characterization的20/21ms测试缓冲及未改变的非DTS估算在其1x/2x有效窗口内，新增单包超总时长分支不改变这些路径。原始失败和跳过分别保留。共享源镜像及历史来源校验通过；工具46项中45通过、1项历史本地证据缺失跳过，具体原因保留。

| 验证阶段 | 通过 | 失败 | 跳过 |
| --- | ---: | ---: | ---: |
| 已消费输入修复 RED | 1 | 3 | 0 |
| 首批共享音频 GREEN | 6 | 0 | 0 |
| 首轮完整 macOS | 915 | 1 | 0 |
| DTS 容器时长 RED | 0 | 1 | 0 |
| 8192帧保守候选相关矩阵 | 30 | 1 | 0 |
| core/低倍速修复 RED | 0 | 2 | 0 |
| 最终 macOS 四类矩阵 | 142 | 0 | 0 |
| 消费者/发现工具 | 45 | 0 | 1 |
| readiness 工具 | 15 | 0 | 0 |

消费者工具跳过原因为 `local historical focused evidence is not present in CI`，不是本轮原生用例跳过。原生SDK/Swift并发及QoS诊断、Xcode的 `command failed with exit code 0` 中间诊断保留在原始日志；最终构建/测试退出码和xcresult实际执行结果分别核对，不删除诊断来制造干净输出。

台账结构验证退出0，`--require-ready`按现有缺口退出1；`releaseReady=false`。102行状态与HEAD逐行比较不变：67 implemented、34 partial、1 unreviewed；69 not_run、30 external_missing、3 failed、0 passed。本轮仅为CAP-FORMAT iOS/macOS和PERF-BASELINE追加记录引用，不提升资格。

证据目录：[本轮证据](evidence/2026-10-29-audio-consumed-packet-admission/)。包括各轮原始失败/通过摘要、执行身份、压缩日志、候选源码哈希、最终构建二进制哈希和SHA256SUMS；完整xcresult/派生构建留在 `/private/tmp/yl-audio-admission/`。早期结果只声明对应源码快照与测试身份，不追认当时未采集的二进制哈希。上述实施验收快照已提交并本地合并，本轮分支已清理；未完成项及原始验收证据继续保留。

## 未完成项

这是一处可控容量失败路径的生产修复，不能证明系统 A5 内存上界、119.084ms READY 根因、物理音画/字幕同步、软件解码热稳态或完整格式资格。P07 完整映射/独立目标/容差与物理 DV、P06 授权、最低系统/设备及远程 CI 缺口保持开放。候选默认关闭及原冻结门限不变，不接管另一聊天 iOS 恢复。
