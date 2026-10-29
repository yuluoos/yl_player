# Android/iOS ABR 恢复续查与集中验收记录

本轮基线 `71018fd5`，工作分支 `codex/abr-recovery`。按用户要求继续查明 iOS 长素材不恢复升档，保留失败，统一测试，更新台账；没有发布。生产播放器、系统 ABR 选择策略、质量约束、依赖及性能门槛均未修改。产品源码身份仍为 `77fdcdc820e805edfbea670ac670c9181bb69defc7171b65a24716cab37dc37c`。

## 结论与仍未完成项

**iOS 的失败已取得原生系统证据，但恢复修复尚未完成。** 在当前 iOS 27 模拟器上，项目链路与绕过项目编译器/代理/后端的 AVPlayer 直连控制，都出现原生分片下载计时器约 2 秒触发、640×360 高档进入 penalty box、记录 CoreMedia `-12889`，随后直到 120 秒节目结束均未观察到升档。这证明项目代理不是该现象出现的必要条件；不能据此推断所有系统版本、物理设备或其他素材相同，也没有证明 penalty box 的退出策略或全程状态。

Android 延长到 120 秒后两轮都恢复请求高档并恢复输出高档；原 40 秒失败中恢复阶段只剩约 0.675 秒的视频请求尾部，存在 EOF 截断观察。延长素材是单独诊断，不替代冻结 40 秒结果或完整资格验收。

本轮确认并完成的是**诊断工具缺口修复**：明确节目时长与完成判定、记录公共带宽估计与视频请求尾部、加入同媒体系统直连控制、修复控制服务器 HLS MIME、补齐原生错误/缓冲/时钟/运行身份收据。没有证据支持直接修改产品策略；不通过强制升档、重建 item、改变 profile 或门槛把失败变成通过。

iOS 仍需研究并验证受支持的恢复办法，覆盖连续播放、音画同步、字幕、DRM、seek 和 auto/caps/fixed 约束；这仍是工程问题，不能全部归为缺设备。Android 仍需物理设备/API 24 与完整矩阵。iPhone 实机、最低系统、32 位/Intel、授权 DRM、Dolby 原始参考和物理输出等缺口沿用原台账保留。

## 冻结条件与证据入口

原始证据位于 [evidence/2026-10-27-abr-recovery](evidence/2026-10-27-abr-recovery/)。`SHA256SUMS` 绑定归档文件；`archive-provenance.json` 记录未压缩原文件 SHA-256、大小、原路径及归档路径。日志及较大 JSON 仅无损 gzip；八个原生 `.xcresult` 分别归档。生成的重复 `.m4s/.mp4` 不重复收录，保留每轮 manifest、素材清单与 hash，可由版本化原素材重建。`source-final/` 保存最终诊断源码与差异，阶段源码身份以各阶段 `source-identity.json` 和运行制品 hash 为准；不能把最终探针冒充早期探针。

旧报告与原始失败保持不变：[上轮集中验收](2026-10-26-remaining-acceptance.md)、[主分支合并核对](2026-10-27-remaining-main-merge.md)。本轮保留红灯测试、编译失败、所有未升档运行和相互矛盾的探索结果。

| 条件 | 身份/说明 |
| --- | --- |
| 原 profile | `down-and-recover-v1`，SHA `4e4f256c59465f4a573d6ab1c48f7a7571294638025088d0cddba9325f5032ea` |
| 原限速 | 0 秒 500000 B/s + 40 ms；10 秒 50000 B/s + 200 ms；25 秒恢复 500000 B/s + 40 ms |
| 40 秒 MPD | `ee00dce275ab3361397bc369a9e3af759efbf6226b5b350d258d0cb34501debb`，10 periods/161 assets，默认字节未变 |
| 120 秒 MPD | `1be00f4b713ecdcaf00a5744ba344b6973d67db764e3f4aa65bdf613da46ceb6`，30 periods/481 assets，单独身份 |
| 120 秒素材清单 | `34c75b407f19c01ea4db1706ed47c0c85431e4b07e149e062fc136e815a523a0` |
| headroom 对照 | 仅恢复段上限改为 2000000 B/s；SHA `a594236ddb63aa7c854d962fad1a6e56d5f7ccdae5f20f4a11b99deb7685ac92`；独立临时 profile，不写入冻结 profiles.json |
| 原生直连 | 同媒体字节、时间线、码率 414000/764000、音频组；直接 HTTP HLS，额外四份 playlist；不使用项目 DASH 编译器/代理/播放器后端 |
| 环境 | Apple M1 / macOS 27.0.1 / Xcode 27.1；iPhone 18 Pro Max / iOS 27 Simulator；Android TV API 36 arm64 只读模拟器 |

限速是上限，1024 字节分块与调度/休眠使实际吞吐低于标称；不能把配置 B/s 当观测 Mbps。AVPlayer `observedBitrate` 是媒体下载吞吐估计，不是瞬时可用链路容量；`indicatedBitrate=-1` 只表示未知，不能单凭它认定入箱。相关语义核对本机 AVFoundation SDK `AVPlayerItem.h`，系统入箱结论来自本轮日志，不依赖错误码猜测。

## 六次公共 auto 运行

所有运行均完成采集、自然片尾与清理，三阶段都有媒体流量，无模式约束违规；`capabilityAccepted/physicalOutputVerified/baselineComparable` 均为 false。

| 运行（runs/） | 降档后升档 | 最后视频请求结束（profile 秒） | 恢复后的请求尾部跨度 | 请求失败 |
| --- | --- | --- | --- | --- |
| android-auto-40-r1 | 否 | 25.675 | 0.675 秒 | 0 |
| android-auto-120-r1 | 是 | 105.321 | 80.321 秒 | 0 |
| android-auto-120-r2 | 是 | 105.133 | 80.133 秒 | 0 |
| ios-auto-40-r1 | 否 | 30.462 | 5.462 秒 | 1 |
| ios-auto-120-r1 | 否 | 110.540 | 85.540 秒 | 1 |
| ios-auto-120-r2 | 否 | 110.637 | 85.637 秒 | 1 |

Android 两次 120 秒高档请求分别在恢复后约 0.996/1.969 秒出现，公共输出升档约恢复后 16.14–16.20 / 16.91–16.98 秒。请求发生与画面呈现不同步，不能混成一个延迟。iOS 每轮保留一次高档请求 `client_io_error`。尾部跨度只定义为最后非空成功视频 chunk 结束时间减 25 秒，不是连续网络占用时长，排除音频与 init。iOS 长素材仍有约 85.6 秒请求尾部，因此单纯延长观察不能解释其未恢复。

## 八次原生运行与带宽对照

八次原生收据 `passed=true` 表示诊断采集、进程清理与制品身份检查通过，**不表示升档通过**。全部 `capabilityAccepted=false`。下表四次升档、四次未升档均保留，不能只选成功结果。

| 阶段/运行 | profile | 降档后升档 | 最后 observedBitrate（bit/s） | 适用范围 |
| --- | --- | --- | --- | --- |
| native/original | 原 | 否 | 1391437 | 旧探针；脚本注入 120 秒夹具，末位置另核对 |
| native/headroom | headroom | 是 | 3349769 | 旧探针带宽探索 |
| controls/direct-original | 原 | 是 | 1984488 | 新直连探索，启动时序不同 |
| controls/managed-original | 原 | 是 | 1901950 | 探针曾把 AVPlayer 创建移到预取之前，有混杂 |
| controls/managed-headroom | headroom | 否 | 2764464 | 同一初始化顺序混杂；反证高带宽必然恢复 |
| controls/direct-headroom | headroom | 是 | 3640243 | 同媒体直连探索 |
| causal/managed-original-order | 原 | 否 | 1575462 | 恢复原 managed 初始化顺序，显式 120 秒/零延迟 |
| causal/direct-delayed | 原 | 否 | 1582246 | 先 GET MPD 启动 profile，再延迟 1000 ms 直连 HLS |

中间四轮是探索，不是产品修复后的验收。最终默认 managed 路径保持先 prepare、后创建 AVPlayer 的原顺序。直连延迟是显式诊断变量，边界 0–2000 ms、默认 0；无生产影响。最后两轮均用当前探针、原 profile 完成 120 秒，最后宽 320，均观察到 471 帧；原生 buffers 保持可继续播放，不能把“没卡顿”解释成恢复升档。

## 原生失败链路

精简事件在 [causal/key-events.json](evidence/2026-10-27-abr-recovery/causal/key-events.json)；同目录 `*-error-context.json` 和 `*-system-log.json.gz` 保留带时间/PID 的原始上下文及查询命令。时间为本机 -0700。

| 事件 | managed-original-order（PID 50665） | direct-delayed（PID 51283） |
| --- | --- | --- |
| MediaHandleDownloadTimer | 02:33:15.681673；received 0 bytes in 2.00189 seconds；latency 244 ms | 02:35:27.287304；received 0 bytes in 2.00073 seconds；latency 245 ms |
| MoveAlternateToPenaltyBox | 02:33:15.683617；Peak 764000 / 640×360 | 02:35:27.288340；Peak 764000 / 640×360 |
| 错误追加 | 随后约 15 ms，CoreMedia -12889 | 随后约 15 ms，CoreMedia -12889 |
| 初次错误 profile 时间括号 | 12.606–12.680 秒 | 12.819–12.867 秒 |

触发在弱网段，早于 25 秒网络恢复。这里 `received 0 bytes` 是 AV 内部日志计数，**不代表网络没有传输字节**。服务端 managed 高档请求 period4/chunk-1-00004 为 10.518–12.617 秒、部分写出 63488 字节后 client_io_error；直连 period4/chunk-1-00003 为 10.586–12.593 秒、完整写出 60790 字节。它们不是相同 segment，也不是相同服务端完成状态；服务端 write 完成不证明客户端接受并解码完整分片。二者共同证据是原生计时器及高档入箱后没有观测到恢复，不夸大为逐字节等价实验。

日志 `processImagePath` 的安装容器为 `6E08E14C...`，运行 `process.json` 分别为 `66200AB9...` / `DDAD6845...`，路径不一致原样保留。两者 PID、时间、模拟器与 Mach-O UUID 一致；本轮 `dwarfdump --uuid` 核对 Runner 为 `40FC0D42-E85A-3F12-8A1B-FE3EA48FEE7D`，与日志相同。不宣称安装路径相同，也不依赖路径单独归因。

检查现有代理取消/错误路径，未确认“客户端取消后迟到回调生成 502”的产品缺陷：取消会先移除请求记录；迟到完成被忽略；响应头之后错误关闭连接而非改发 502。代理配置的上游超时为 15/25 秒，与此 2 秒原生计时器不同。当前结论不足以安全决定强制换档或重建播放器。

## 实施与集中检查

工具支持仅 40/120 秒合法整数；总结器按声明时长检查片尾，拒绝 120 秒任务在 40 秒结束、错 transport/错 delay/旧 host 元数据。原生探针增加 errorLog 最近 32 条、URI 有界脱敏、downloadOverdue、loaded ranges、buffer flags、timeControlStatus，以及与运行 profile 身份绑定的时钟括号。公共采样增加 nullable estimatedBitrate。直连 HLS MIME 修复及所有边界有回归测试。

| 本轮实际检查 | 结果/证据 |
| --- | --- |
| playback_network 全部 Python | 87/87 通过；checks/yl-abr-recovery-network-final-candidate.log.gz |
| playback_benchmark 全部 Python | 294/294 通过；checks/benchmark-tests.log.gz |
| example 全部 Dart 单元 | 109/109 通过；checks/example-tests.log.gz |
| Flutter analyze / 三份 Dart format | exit 0；checks/analyze.log.gz、format.log.gz |
| 公共 API 与产品源码 parity | exit 0；checks/public-surface.log.gz、source-parity.log.gz |
| 当前 Apple 测试镜像 | iOS 822 / macOS 866 声明一致，exit 0；不是运行通过数量 |
| iOS 最新探针 build-for-testing | exit 0；checks/yl-abr-recovery-errorlog-build.log.gz |
| macOS 最新探针 build-for-testing | exit 0；checks/yl-abr-recovery-macos-final-build.log.gz |
| Android/iOS 公共运行 + iOS 原生 | 6 + 8 次完整采集；结果逐轮见上表，恢复失败仍开放 |
| 台账、阈值结构 | exit 0；sourceMatches=true，releaseReady=false |
| 台账、阈值 --require-ready | exit 1（预期缺口），未放行 |

测试驱动的失败记录和构建失败均归档：初次 iOS build 引用了已删除临时 Flutter integration listener；重新生成 config 后又暴露测试镜像缺少 `@testable import yl_player_media_core`，补回镜像专属 import 后构建通过。最终探针后来再次编译通过；macOS 同步编译通过。原测试红灯里另有非提权运行 ps 的沙箱错误，保留但不将其计为产品失败。构建警告仍在原日志。

benchmark/example/analyze 等在后续原生诊断扩展前已完成；后续只涉及 Python 网络诊断工具、Swift 测试探针与文档，最终 87 项网络测试和两端编译覆盖相应变化。生产源码/依赖未变，故复用上轮产品矩阵，不声称本轮重跑：基础 Python 637（635 过、2 skip）、Dart 2333 后遇 FFmpeg 拉取 TLS 失败且补充契约检查；Android JVM 初次 563（560 过、3 可选 skip）及后补 4 项 RTMP；macOS 累计 860 通过；iOS 累计 782 通过但仍有 33 解码/输出失败和 1 skip；5 个消费者构建与 9 个包 dry-run。累计和补测不伪装成一次全绿。P08 性能/资源与正式基线仍未完成。

本轮集中独立代码/证据复审及最终文档核对另留 review 记录。清理仅针对本轮拥有的服务/进程/Android emulator，保留用户已有模拟器；进程与制品身份清理收据随各次运行归档。

## 台账与后续解除条件

仅为 CAP-ABR Android/iOS 追加本报告并更新 nextAction。两行继续 `partial / not_run / acceptance=null`，`not_run` 指完整组共同验收尚未完成，不抹去上表执行。全台账仍为 102 行、67 implemented / 34 partial / 1 unreviewed，验证 30 external_missing / 3 failed / 69 not_run / 0 passed。

Android 下一步为延长观察的物理/API24重复与完整模式矩阵；iOS 下一步为原生下载计时器触发高档入箱后的受支持恢复策略与跨系统/实机复现，保留原始 40/120 秒失败及带宽对照。不能用提高恢复带宽、改变分片长度、延后弱网开始或降低升档要求替代原条件验收。设备/授权缺项原样保留。没有创建任何完整 acceptance 声明，没有发布、上传或打标签。
