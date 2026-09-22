# Apple 明文 DASH 适配 Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development，按任务独立测试/审查；用户已授权继续实施，不重复询问执行方式，不自动提交或发布。

**Goal:** 在 iOS/macOS 落地可验证的明文 static AVC/AAC fMP4 DASH 基础播放，使用受控虚拟 HLS 清单和现有 AVPlayer 输出。

**Architecture:** 有界 MPD 编译器先验证初始支持子集，生成会话私有的 HLS master/media 注册表；真实初始化与媒体请求全部经现有 loopback proxy，保留源凭据祖先关系。新增明确 DASH 路由并复用 prepared-HLS 的候选/恢复/清理所有权，原始 source 身份不改写成 HLS。

**Tech Stack:** Swift/Foundation XMLParser、AVFoundation、现有 YlHlsResourceLoader/MediaProxy、Flutter integration_test；不引入商业 SDK 或额外原生媒体依赖。

**Spec:** [已授权需求](../specs/2026-09-20-playback-expansion-requirements.md) REQ-02/04、REG-API/NET/BUF/DEC/LIFE/AUDIO/DIAG；[可行性核查](2026-09-22-playback-feasibility.md)。本批是阶段性支持子集，完整 DASH 目标不变。

## Global Constraints

- Android API24、iOS15、macOS12 下限不变；不接入商业 SDK，不破坏上一批未提交改动。
- 私有 schema3/public SPI2 及公开 dash 枚举保持；不增加无实际能力支撑的公开声明。
- Apple AVPlayer 路线仍拒绝 managed 网络、buffer.bounded、hardwareRequired；不能以代理网络存在为由宣称实现完整预算或硬解证据。
- MPD/初始化段/媒体段保留来源凭据祖先关系：任一跨域后返回原域仍剥离，普通头保留；虚拟清单身份不能成为凭据原点，不能向上游请求虚拟 URL。
- MPD/生成清单/分段列表分别有界；不是媒体 buffer.bounded 账本。取消、替换、候选失败回滚和恢复保留原所有权契约。
- 不透传签名 URL、脚本任意文本、请求头、原生异常；安全错误有稳定码。PD-01/02/03 不作新决定。
- 生成 HLS 不能当作通用 DASH 完成。SegmentBase、动态/加密、非零 PTO、缺口/重叠、任意轨道/编码变更、ABR/字幕仍明确未完成，后续补齐。

## 支持子集与拒绝条件

static MPD；网络 HTTP(S)；AVC 视频+可选 AAC-LC 音频，分离 AdaptationSet，每 Period 一个视频和至多一个音频 Representation；各 Period 对应轨道 codec/尺寸/采样率/存在性一致。Period 有限连续、从0开始，时间轴样本起点0且 presentationTimeOffset=0。允许 BaseURL 分层继承，每层仅一个选择；多候选暂拒绝。SegmentTemplate（Number/Time/RepresentationID/Bandwidth，有限 duration 或 Timeline）和 SegmentList（明确 URL、可选 byte range），init必需。尾段/片段时长必须覆盖该 Period，不默默剪掉未验证样本。

拒绝 dynamic、ContentProtection、SegmentBase、XLink、外部时间/定位/steering、未知必要功能、非 HTTP(S)/userinfo URL、未知/负持续时间、不安全模板格式/整数溢出。没有播放数据证明的 PTO/时间轴不做猜测转换。普通注释/无关元数据不会触发远程资源访问。

初始硬上限：MPD 2 MiB，XML depth64，XML elements100000，Period64，展开段100000，单URI8192 UTF-16单元，累计URI4194304单元；生成单playlist2MiB、所有virtual registry4MiB。预算在展开/追加/保留之前检查，数值解析和乘除使用有界整数；外部实体禁用并拒绝DTD。

依据：[Apple CMAF/HLS](https://developer.apple.com/documentation/http-live-streaming/about-the-common-media-application-format-with-http-live-streaming-hls)描述 fMP4 的 MAP/Range/discontinuity；[DASH-IF timing model](https://dashif.org/Guidelines-TimingModel/)定义 Period/PTO 映射。实际小型 macOS AVPlayer 探针已输出同一合成双 Period 夹具，8秒duration、seek5秒后持续输出；仅说明此样本的适配可行，不证明任意 MPD。

## Task 1: 有界 MPD 到虚拟 HLS 编译器

**Files:** 新增 Apple `Shared/DASH/YlDashHlsCompiler.swift`（如需要，纯模型独立同目录文件）；新增当前 canonical `tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashHlsCompilerTests.swift`，镜像到 example iOS/macOS，使用已有 Ruby xcodeproj 方式仅注册新测试文件到两端 RunnerTests PBX Sources；更新 current inventory计数/README，历史清单不改。

**Interfaces:**

```swift
struct YlDashHlsPresentation {
  let rootURL: URL
  let manifests: [URL: Data]  // 已经全部改写的、仅本地读取的虚拟清单
  let strippedResources: Set<String> // 真实上游 URI；重复路径取最严格结果
  let durationUs: Int64
}
enum YlDashHlsCompiler {
  static func compile(
    data: Data, finalManifestURL: URL, sourceURL: URL,
    credentialsStripped: Bool,
    manifestURL: (String) throws -> URL,
    mediaURL: (URL, Bool) throws -> URL
  ) throws -> YlDashHlsPresentation
}
```

Task2 传入每次 Load 唯一的虚拟 master/video/audio HTTP(S) 身份 URL 和已存在 proxy 的 `mediaURL` 闭包。`rootURL` 和 `manifests` keys 是未编码虚拟 HTTP 身份；master 内的子清单引用必须由 `YlHlsURLCodec.encode(id, kind: .manifest)` 编为自定义 scheme，绝不能原样请求虚拟 HTTP 地址。`mediaURL` 返回已完成的 loopback proxy URL，原样嵌入。loader 解码后用身份查注册表，registry模式下所有未知身份/kind在网络前拒绝。编译器先收集/验证祖先与重复 URI 的剥离，再生成 playlist，不能先生成可携带凭据的旧 URL、后发现冲突而不修正。网络抓取、AVPlayer、任务状态不进入编译器。

- [x] 先建立上述最小拒绝stub和行为测试：有效单/双Period的预期 HLS MAP/EXTINF/discontinuity、真实URL闭包及总duration，运行观察 unsupported 行为红灯，不能用编译失败替代。
- [x] 实现有界 XML 结构、继承、模板/Timeline/List 和资源模型；验证源/最终 MPD URL 与每层 BaseURL，保留跨域后返回原域的剥离，重定向stripped参数不可恢复。初始化和媒体URL全部经过media闭包。
- [x] 安全生成 master/audio/video HLS：固定安全标签，不插入原始任意 XML 文本；EXT-X-MAP/EXT-X-BYTERANGE、Period边界discontinuity一致，ENDLIST/VOD。每个虚拟身份唯一且在注册表内。
- [x] 定向行为测试：单/双Period、Number/Time/template继承、SegmentList+range、同源/跨域返回/最终重定向、重复URL最严剥离；static动态/DRM/PTO/gaps/missinginit/multiplevariants拒绝；恶意DTD/深度/巨型repeat/格式宽度/URI展开及整数溢出有界失败。新编译器错误为固定 `container.unsupported`，不含源URI/XML。
- [x] 使用现有 Apple build/helper 流程执行 macOS 编译器类并核实真实测试数；当前canonical/iOS/macOS镜像字节相等、current/historical gates通过。需要pod源列表刷新时按已有工具生成，不改发布配置。报告红绿命令/数量，交独立审查。

示例：双4秒Period应生成每条媒体列表恰好1个 discontinuity、各段对应的init MAP，durationUs=8000000；跨域BaseURL再绝对回原域时闭包收到 stripped=true。

## Task 2: 会话私有清单与 Apple 播放路由

**Files:** `Shared/HLS/YlHlsResourceLoader.swift`（有限扩展virtual registry/MPD preflight），必要时新 `Shared/DASH/YlPreparedDashAsset.swift`；`Shared/Session/YlFallbackModels.swift`、`YlAppleSessionCoordinator.swift`、`Shared/SourceRouting/YlEngineRouter.swift`、`YlSourceAssessment.swift`、`Engines/AvPlayer/YlAvPlayerBackend.swift`；相关 canonical+example 路由/loader/ownership测试与当前inventory。

**Consumes:** Task1编译器；现有 `YlHlsCredentialContext`、prepared HLS discard/take、opaque HLS retention、cancellation token。
**Produces:** `.dashHls` 原生 route（映射公开 avPlayer）和真正预检的资产；root MPD 身份一直保留，普通 HLS 行为不改。

- [x] 路由行为RED：显式dash或`.mpd`非严格网络候选 requiresInspection/dashHls；严格网络/缓冲/硬解及live/local不在初始subset，仍明确拒绝。既有Apple“拒绝全部dash”测试更新为本阶段契约，不减少严格策略断言。
- [x] MPD使用同一 owned loader网络、有限body、最终responseURL及完整strip历史抓取；Content-Type不是唯一识别依据。不要把XML交给HLS rewriter。每次Load有唯一virtualnamespace，未知虚拟URL、错误kind、取消后的请求fail closed，不能流向URLSession。
- [x] 编译成功后以不可变registry供资源加载，allData/range/contentLength正确，UTF8 playlist MIME/UTI正确。所有init/media必须经session proxy，即使没有显式凭据；不要添加直接上游AVPlayer路径。先登记strippedResources再暴露asset。
- [x] 复用prepared ownership，candidate失败只discard自身；stop/dispose清空registry、任务/连接和retention；恢复/重新激活保留dash路由并重建正确的privateasset，旧完成不发布。
- [x] 原有HLS/AVPlayer路径、严格拒绝、loader Range/取消/重定向、candidate rollback与audioownership不退化。定向native tests包含virtualmiss无网络、registry总量、预检取消、upstream403安全错误、输出/loader释放。
- [x] macOS targeted native + iOS对应类，核实实际测试数；current/historical fixture gates；报告确切范围和缺口交独立审查。

## Task 3: 两端真实播放与凭据证据

**Files:** 新 `example/integration_test/apple_dash_playback_test.dart`，复用已有 `support/dash_server.dart`，仅按需要扩展支持MPD重定向/无效MPD；复用既有DASH assets；native/controller测试不作为真实呈现替代。

**Consumes:** 原公共 `YlMediaFormat.dash` + Task2路由。
**Produces:** iOS与macOS实际Flutter→AVPlayer输出证据。

- [x] 首帧关联当前session、明确avPlayer、8秒programme timeline；显式无扩展名与automatic `.mpd`；播放跨Period边界、seek5秒后继续到完成，反向seek回第1段，误差阈值在代码中固定。
- [x] 同源manifest/init/media的Authorization/Cookie/自定义凭据存在；跨域BaseURL→原域及MPD重定向跨域→返回原域保持剥离，普通头存在；实际init/media请求验证。
- [x] 已播放源上加载不支持/畸形MPD时回滚不破坏旧会话；pending MPD/segment时stop与快速替换，旧任务不发布。403/缺失段错误安全，不能一概声称HTTP码能穿透AVPlayer媒体错误，按真实可得证据分类。
- [x] 分别运行macOS与已安装iOS模拟器的集成文件；遇环境问题定位，不删除失败断言。Windows/Android不是本任务运行目标；Android旧suite仅跨共享文件变更时定向验证。
- [x] 更新平台矩阵/可行性/永久报告为实现+证据+缺口。完整AppleDASH/ABR/字幕/DRM未完成；真机和最低系统未测试要明确记录。

## 完成判定

三项独立审查和整体集成审查无阻塞项；两端真实输出、timeline、凭据和取消有记录。若媒体proof否定适配，保留证据并修正路线，不用“XML转换成功”代替播放通过。完成本批仍不是三端完整需求验收。
