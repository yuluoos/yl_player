# 播放器扩展：架构核查与实施入口

初始核查日期：2026-09-22；初始代码基线：1128897，2026-09-24 补充状态。依据[已授权需求](../specs/2026-09-20-playback-expansion-requirements.md)。本文记录候选路径与缺口，不是发布支持表；错误语义首批已实施，DASH 基础批已完成，[Apple DASH 静态子集适配](2026-09-22-apple-dash-adapter.md)已实现并通过三端定向回归；独立 JS 解析模块也已完成三端受控运行与媒体交接检查；各批证据单独记录。

2026-09-24 后续已扩展 Apple 兼容多档位清单，macOS/iOS 定向原生各45项、公开播放各1项通过；实际仅观察到低档，尚未验证弱网升降档或固定清晰度接口。用户提供的 tvs 业务项目已接入 JS/RTMP 并通过93项目标测试，尚未执行完整应用/真实订阅验收。PD-01 档位缺失行为已确认自动回到自动清晰度，PD-02/03 仍未确认。详见[后续实施报告](../reports/2026-09-24-dash-variants-and-live-integration.md)；下表保留各初始阶段的证据边界。

2026-09-24 固定档位阶段已提交为 `76b99d7`：公开选择/状态契约与 Android Media3 真实固定、跨 Period 语义重绑、PD-01 自动回退已实现；最终两个 Android 受控播放用例通过，详见[固定档位报告](../reports/2026-09-24-fixed-video-selection.md)。Apple 固定仍明确 unsupported。后续[Apple 跨 Period 档位变化阶段](2026-09-24-apple-dash-changing-ladders.md)已实现兼容明文 AVC 节目的档位增删与完整路径播放，iOS/macOS 各三个受控用例通过；详见[该阶段报告](../reports/2026-09-24-apple-dash-changing-ladders.md)。跨段档位改动已提交为 `d1b5b65`，自动播放扩展不等同固定/严格上限/弱网 ABR 验收。上面的早期“尚未固定接口”仅描述此前阶段。

## 1. 架构门槛

2026-09-26 继续[Apple DASH 错误归因阶段](2026-09-26-apple-dash-diagnostics.md)：已完成五类已知清单拒绝原因和安全提示贯通；两端原生各102项、Dart233项、公开诊断各五例及独立回滚各一例通过，最终独立复核通过，阶段尚未提交。保持既有支持范围和失败候选回滚；验证记录见[报告](../reports/2026-09-26-apple-dash-diagnostics.md)。

2026-09-26 [Apple DASH 固定档位与缺档回退](2026-09-26-apple-dash-fixed-selection.md)已完成既有公开选择契约和已确认 PD-01：固定选择约束真实媒体路径，确认当前 Period 缺档时安装自动路径，随后回跳仍保持自动。受支持范围为既有兼容明文 static AVC/AAC DASH 子集；macOS/iOS 公开播放各三例及分批原生定向验证通过，两项任务复核和整阶段复核通过，非阻塞覆盖与告警限制见[验收报告](../reports/2026-09-26-apple-dash-fixed-selection.md)。该阶段已提交为 `685a22a`，不代表完整 DASH、DRM 或弱网 ABR 已完成。

2026-09-26 进入[Apple DASH 运行时上限事务](2026-09-26-apple-dash-runtime-caps.md)：从已接受的原始 MPD 快照重新投影，异步命令等待安装提交，保持会话身份及最新位置；准备失败保留原播放。原生与公开播放定向验收已通过，整体复审发现的并发跳转问题已修复并通过定向复核；各批次证据及边界见[验收报告](../reports/2026-09-26-apple-dash-runtime-caps.md)。该阶段已提交为 `f3b2cd3`。

2026-09-25 严格 Load 上限阶段已提交为 `2aa997c`。已实现[Apple DASH 当前 Period 档位目录](2026-09-25-apple-dash-track-catalog.md)，已完成验收及整体复审，该阶段已提交为 `b44d95e`：用经过验证及上限过滤的 MPD 档位替换 AVAsset 轨道推测，保留精确时间边界和稳定身份；固定选择/运行时事务仍待后续交付。

2026-09-25 跨段档位阶段已提交为 `d1b5b65`。[Apple DASH 加载时严格上限](2026-09-25-apple-dash-load-caps.md)已实现每个 Period 候选过滤与真实输出检查。macOS/iOS 公开播放各四例通过，随后加强的脱敏异常用例各一例通过；原生与公开证据分批记录在[上限验收报告](../reports/2026-09-25-apple-dash-load-caps.md)，本阶段改动随严格上限实现提交交付。现有 active AV item 替换尚无完整回滚/恢复事务，运行中改限与固定选择仍需后续独立实现；本阶段不能把 AVPlayer 偏好或加载时过滤描述成完整运行时 ABR。

| 能力 | 仓库证据 | 候选路径与依据 | 下一步必须证明的内容 | 当前判定 |
|---|---|---|---|---|
| CAP-DASH / Android | 已接入同版本 Media3 1.11.0 DASH 模块、显式/自动格式路由和受控 MPD 凭据图 | 同版本 DASH 模块接入现有受控 DataSource；官方支持独立音视频 AdaptationSet、多 Period 与自动选档 [A] | URL/显式 format/桥接/能力评估贯通；MPD、初始化段和媒体段均遵守请求策略；跨段 seek、取消与候选回滚 | 明文 static MPD 基础实现已接入，JVM 路由/解析通过；合成双 Period 的 Android 设备集成 6/6 通过，覆盖边界见[本批报告](../reports/2026-09-22-dash-foundation.md) |
| CAP-DASH / iOS、macOS | 已实现有界 static AVC/AAC fMP4 MPD 编译器和会话私有 AVPlayer 加载路由。既有 FFmpeg 制品无 DASH demuxer [L1] | 首阶段选定会话私有 HLS 适配复用 AVPlayer；直接系统播放 MPD 不作为能力声明 [B] | SegmentTemplate/Timeline/List/Base、Range、分离音视频、多 Period 的统一时间轴；不同封装是否需独立路由；凭据、ABR 和缓存账本 | 编译器、加载器及实际播放发现的生命周期修复已独立审查通过；最终 macOS / iOS 公共播放各 13/13 通过；完整覆盖及未支持项仍需后续实现与验证，见[阶段报告](../reports/2026-09-22-apple-dash-adapter.md) |
| CAP-DRM / Android | 主输出为 Flutter SurfaceTexture；尚无 DRM 配置/许可证接口 | Media3 MediaDrm/Widevine；cenc 与 cbcs 分行，后者官方要求 API 25+ [C]；受保护输出需验证 SurfaceView 路线 [D] | 许可证生命周期与 POST 策略、密钥轮换、取消；secure decoder + secure surface、字幕叠加；API 24 不被整体抬高 | 候选有依据；真实受保护播放未验证 |
| CAP-DRM / iOS、macOS | AVPlayer 路由使用 AVPlayerItemVideoOutput 取像素；未见 AVContentKeySession 集成 | HLS + 系统 FairPlay + 原生受保护显示候选。Apple 提供内容密钥会话 API [E] | 原生 AVPlayerLayer 与 Flutter 视图接口、字幕/几何、外接保护；应用证书和合法许可证服务；不可依赖解密像素回读 | 架构及真实设备验证待补；用户暂无授权资源 |
| CAP-DV-MAP / 三端 | Apple YlFELMetadata 当前只接受显示元数据 L1/L5/L6，明确拒绝 creative trims；YlFELCompositor 声明不是完整显示管理 [L2] | 保留 FEL 重建工作，单独评估显示映射。libplacebo 当前源码存在 FEL/NLQ 数据结构，可作为研究线索 [F] | 固定候选版本、逐项元数据/CM 覆盖、目标显示参数、独立参考图及误差容限；三端性能与一致性 | 未证明完整映射可行；不可把源码有 FEL 字段等同已完成验收 |
| CAP-DV-OUT / 三端 | 尚无指定外接设备链和信号证据 | 系统输出路线需逐设备验证；完整映射和原生 DV 信号独立判定 | 设备/OS/连接器/电视模式、内容样本、断接恢复及画面对照 | 外部条件缺失；不能从 EDR/HDR 输出推断原生 DV |
| CAP-JS / 三端 | 独立可选 yl_player_source_resolver，QuickJS 2026-06-04 + CryptoJS 4.2.0；原生终止、受控 HTTP 宿主和安全诊断 | 冻结九脚本原始字节，业务显式解析、刷新、取消后交给内核；RTMP 播放能力仍由内核提供 | 真实订阅/外部业务入口；设备与最低系统矩阵；不能从受控响应推出线上可用 | 九脚本及运行层实际 App 检查每端 26 项通过（macOS 合并首轮与单项重测），真实 AVPlayer / Media3 首帧；最终独立复审通过，见[阶段报告](../reports/2026-09-22-script-resolver.md) |
| CAP-RTMP / 三端 | 独立自有 TCP RTMP 接收器；Android 接 Media3 FLV extractor，Apple 接 custom AVIO/FLV + VideoToolbox；禁用网络的 FFmpeg 制品不变 | 普通 RTMP classic AVC 与可选 AAC 直播；10 秒准备期限、15 秒主动读需求期限、有限资源与三次终身自动恢复；HTTP 请求语义不移植 | RTMPS、增强 RTMP、其他编码、真实订阅、最低系统/物理设备及长期稳定性仍未覆盖；API 24 系统 DNS 最多两槽，不能保证终止 OS 查询线程 | 原生边界回归与应用验收证据见[RTMP 阶段报告](../reports/2026-09-22-rtmp-foundation.md)；仅基础子集，不代表完整 CAP-RTMP 或 CAP-LIVE/REQ-08 |

以上下一步由后续对应能力的实施任务负责。外部输入只阻塞相关真机/许可证/参考验收，不阻塞可独立推进的代码。

### JS 模块的恢复与实施证据

2026-09-22 重新检查时，访谈记载的 `/private/tmp/yl-review-script-snapshots` 已不存在。九脚本原有哈希仍是历史证据，但不能声称当前可复现。进入 CAP-JS 实施时先从受控归档恢复，或重新取得脚本并逐个比对冻结哈希；变化的版本单列，不能覆盖原账本。随后本批已从附件引用恢复全部九份原始字节并逐个确认原哈希，归档到当前忽略工作区，随后完成原始字节的受控宿主和三端应用执行；详见[JS 实施记录](../reports/2026-09-22-script-resolver.md)。恢复与静态检查不等于脚本运行通过。

运行时必须支持实际终止与资源限额，不能只对返回 Future 加超时。QuickJS 官方提供内存/栈限制及执行中断回调；本批固定 QuickJS 2026-06-04，已在三端实际应用中执行循环/正则期限、运行中取消、堆超限及再用检查。网络宿主有独立期限、取消与响应限额，真实等待请求取消后还观察服务端断开。当前证据覆盖所测案例，不是所有原生操作的硬实时上界。[QuickJS 官方 API 文档](https://bellard.org/quickjs/quickjs.pdf)

## 2. 实施依赖与完成边界

| 阶段 | 可独立推进的工程工作 | 验收前需要的条件 |
|---|---|---|
| 1：错误语义 | 原生真实原因 → 稳定码 → 安全提示；测试并保持策略不变 | DNS/403/未知/取消和敏感信息回归；不等同全部 ERR 完成 |
| 2：DASH 与清晰度 | 公共格式契约、Android Media3 接入、Apple 路由实验、受控 MPD 夹具 | Apple 路由门槛通过；PD-01/02 对跨段档位和动态范围策略有影响 |
| 3：JS/RTMP/直播 | 冻结九脚本宿主契约；可选模块的超时/终止/取消；RTMP 内核路径与直播两模式 | 九脚本受控契约与真实流分开；新增协议实际播放证据；先冻结指标 |
| 4：字幕/格式 | 按容器、编码、字幕格式逐组合补齐；受控软解与资源上限 | 字幕故障的 PD-03；各平台对应样本与效果参考 |
| 5：DRM/杜比/性能共同验收 | 许可证接口与安全显示实验；FEL 显示映射参考对照；性能基线采集 | 合法授权流/许可证、独立映射参考、外接链路和三端设备档位 |

每阶段产生单独可执行计划和证据记录；只有通过的能力行可更新发布支持文档。当前部署下限、严格网络/硬解/缓存/音频策略继续有效。不在现有分支自动升级 Media3 到文档示例的新版本。

## 3. 核查来源

- [A：Android DASH 官方指南](https://developer.android.com/media/media3/exoplayer/dash)。本地依赖为 1.11.0；网页示例当前为 1.11.1，版本不同，仍需基于实际依赖测试。
- [B：Apple AVFoundation 概览](https://developer.apple.com/av-foundation/)及 [CMAF 与 HLS](https://developer.apple.com/documentation/http-live-streaming/about-the-common-media-application-format-with-http-live-streaming-hls)。文档不构成本项目通用 DASH 支持的证据。
- [C：Android DRM 指南](https://developer.android.com/media/media3/exoplayer/drm)。
- [D：Android 输出 Surface 类型](https://developer.android.com/media/media3/ui/surface)。
- [E：AVContentKeySession](https://developer.apple.com/documentation/avfoundation/avcontentkeysession)及 [FairPlay Streaming](https://developer.apple.com/streaming/fps/)。生产部署凭据与可用授权服务另有准备要求；系统 API 不等于商业播放器 SDK。
- [F：libplacebo colorspace.h](https://github.com/haasn/libplacebo/blob/master/src/include/libplacebo/colorspace.h)。仅主分支调查线索，尚未选择依赖或固定提交，不能作为独立画质参考。
- [G：FFmpeg RTMP 协议文档](https://ffmpeg.org/ffmpeg-protocols.html#rtmp)。上游支持不能代表本项目裁剪制品已支持。
- L1：`packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh` 的构建开关；现有路径详见 [平台支持](../../platform-support.md)。
- L2：`packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlFELMetadata.swift` 与同目录 `YlFELCompositor.swift`。
