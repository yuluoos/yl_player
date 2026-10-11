# P02 执行记录

## 2026-10-11：内部 SRT/WebVTT 解析与媒体时间查询

基线 `fee2518875bb77ff2b437a989712938709aff939`，当前分支 `codex/fel-integration`。用户要求在其他会话执行长播放复验、弱网 ABR 工具时继续剩余项目。本轮选取 P02 独立解析基础，不占用原生构建、生成入口或播放设备。

交付 `packages/yl_player/lib/src/subtitles/subtitle_document.dart` 和对应测试，接口及限制见[内部解析契约](../specs/2026-10-11-subtitle-parsing-contract.md)。解析结果不可变，保留原始 payload/可选标识；重叠字幕以媒体时钟和正负偏移查询，半开时间区间，关闭/回退 seek 无保留状态。WebVTT position/align 保留，样式区域与 HLS timestamp-map 明确拒绝；没有网络或外部资源访问。单独限制输入、行、cue、文本及重叠数量，错误输出脱敏。

### 实施决定和验收边界

- 沿用总览指定 checkout，仅操作本轮文件。共享目录需要逐文件检查，禁止整仓暂存及改动其他会话文件。
- Task 2 的公共接入依赖尚未冻结的 Task 1。先交付内部 parser/query，不新建公开字幕命令、不更改 Pigeon ordinal，不处理视频是否继续的 PD-03。代价是本项仍不能在实际播放器显示字幕。
- 不以本地 Dart 通过替代原生/画面同步或完整 CAP-SUB。Task 1 多轨身份、字幕公开接口；Task 2 TTML、managed 网络/取消/会话、渲染；Task 3/4 高级格式与 HDR/保护输出均继续开放。

### 验证记录

测试运行目录为 `packages/yl_player`；Flutter `/Users/yy2021_8689/flutter/bin/flutter`，Dart 使用同 SDK 的 `bin/cache/dart-sdk/bin/dart`。

1. `flutter test --no-pub test/subtitle_document_test.dart` 初次执行因 SDK 缓存沙箱权限未启动；授权后实际 RED：缺少待实现库/类型，exit 1。保留 `.superpowers/sdd/2026-09-26-remaining-02-tracks-subtitles/red.log`。
2. 实现后定向 **47/47 通过**。继续补充反向 seek/偏移与参考扫描对照、微秒边界、极端输入、行/元数据预算和原子失败测试。
3. `flutter test --no-pub` 整包 **144/144 通过，exit 0**，包含新增测试，日志 `.superpowers/sdd/2026-09-26-remaining-02-tracks-subtitles/package-tests.log`。
4. 初次静态检查出现一处 if 括号风格提示，已修正；最终结果及独立复审见下方追加记录。

本轮不运行原生、模拟器、物理设备、长期播放或 UI 截图。输入素材为测试内原创字符串，未取用用户媒体或服务。完整 P02 状态仍为进行中。

### 最终复审与修复后验证

一次独立只读复审发现 Important：NOTE 块未检查箭头，缺少空行的后续字幕被静默吞掉。三个新增用例首先真实失败（空文档和有效前缀均覆盖），随后逐行校验 NOTE，整包最终 **147/147 通过、0 失败**；静态分析 **No issues found**。没有再次原生构建或设备测试。

复审另提一项文档措辞歧义：本契约前句已明确 position/align 之外的 setting 为 unsupported，后句“未知/重复/损坏已支持 setting”指已支持项的非法值；此处明确：未知名称为 unsupported，非法 align/position 值及重复已支持项为 malformed。保留实现，不改变已冻结边界；误读的成本是错误原因预期不同，不影响字幕内容安全。

复审列出的公共身份/命令、网络/取消、TTML/图形字幕、原生渲染、HDR/DRM、PD-03 均按本切片边界继续开放，不能将此次通过外推到这些项。无其他未处理 Important/Critical。

为保持其他会话播放证据的 HEAD 身份，改动保留工作区，不暂存、不提交、不推送。代价是需后续合并提交，已保留源文件指纹和原始验证日志。

[证据清单](evidence/2026-10-11-subtitle-parser/manifest.json)记录源码/测试/契约 SHA-256、命令和原始日志哈希，红灯及最终结果一并保留。下一步仍是 Task 1 的字幕公开命令/身份契约，再接媒体会话和画面；PD-03 仅限制故障恢复决策。

用户随后明确要求 commit 后继续；提交前核对三个源码/契约指纹与四份原始日志一致，147 项与静态分析证据有效。本提交只包含 P02 文件；P04 已独立提交为 b8a83c9。

## 2026-10-11：Task 1A 字幕公开 Dart 契约

解析切片已提交 `a8acb0b`；通用日志忽略规则排除的四份原始证据另补提交 `fd24126`。以 `fd24126` 为本切片起点，沿用当前 checkout；并行会话后续提交的 `a50767b` 和未提交 ABR 改动不属于本项。

### 交付和决定

新增公开 YlExternalSubtitle/YlSubtitleTrack/YlSubtitleState/YlSubtitleFormat，包含请求策略、语言/role/内容身份、VobSub 成对资源和有限目录校验。YlPlayerState 默认关闭字幕，copyWith/equality/hash 包含字幕快照。现有音视频轨道 ordinal 不变；Dart capability 末尾追加三项，可选 SPI 与 capability 双门禁保护旧适配器。

会话增加 replaceExternalSubtitles、selectSubtitleTrack(null 即关闭)、setSubtitleOffset。列表在派发前复制；成功或失败回包后重新检查会话，切源、Stop、Dispose 后不能返回旧会话成功。命令不乐观发布字幕状态，格式身份不构成播放支持声明。详见[公开契约](../specs/2026-09-26-subtitle-contract.md)。

Task 1A 只完成 Dart 合约，native schema/生成文件保持不变，且当前原生适配器不广告三项字幕能力。后续才能落实下载取消、同会话命令顺序、原子替换、实际 cue/画面合成。多音轨真实选择和 PD-03 没有被此契约决定；Task 1 整体与 CAP-SUB 仍开放。

### 失败与回归

- 新合约与会话用例均先实际 RED（缺失 API），随后定向 9/9 和 23/23；再补公开导出和权威状态/失败回滚检查。
- 平台接口首轮130通过/2失败，原因输出为旧 conformance.timeout（原门限80ms）；保持用例/门限不变的串行运行132/132。保留首轮失败，不将其称作确定的根因修复。
- Apple 首轮109通过/3失败，其中两项是旧“全 Dart/native enum 对等”假设，另一项是执行目录不符合 schema 文件相对路径。Android 首轮79通过/2失败，同为枚举预期。
- 兼容测试改为精确原生子集，仅排除三项尚未进入 native 的字幕能力，并新增“原生不广告字幕、状态默认关闭”的断言。从仓库根正确入口执行，Apple113/113、Android82/82；播放器171/171。
- 静态分析最终 No issues found。Pigeon schema/生成物 git diff 为空；为避免共享生成/原生构建冲突，本轮不重生成、不运行原生构建或设备。此项不冒充新的 Pigeon-generation/native gate。

一次独立复审无 Important/Critical。非阻断建议暂缓：session 测试 matcher 检查 code/scope，尚未额外锁定 unsupported category/retryable=false；实现通过既有 _exception 正确返回这两项。后续可补强化断言。

最终集中验收和源码指纹见下方追加记录；初轮失败保留，不以最终成功抹去。下一项为可用适配器的字幕加载/取消与媒体时钟渲染接入，期间继续推进 TTML 和 Task 1 音轨身份。

最终冻结源码的集中命令：从仓库根运行 `flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test`，**498/498、0失败、exit 0**。原80ms/30ms测试门限未修改；静态检查无问题。四个包覆盖数为132/171/113/82。[契约证据清单](evidence/2026-10-11-subtitle-contract/manifest.json)保存15份源码/测试/规范指纹与7份原始日志；本切片将独立提交，不包含并行网络工具与example验收改动。

## 2026-10-11：Task 2 外挂文本字幕加载与渲染

起点为 `0c2cd0a`，并行 P04 提交和长播放工作不属于此切片。沿用已授权 P02 计划，接通真实文件/HTTP 读取、字幕目录、媒体位置查询和 `YlPlayerView` 叠层。启用方式是 `YlPlayerController.create(enableTextSubtitles: true)`；现有默认 native SPI 门禁保留，不能同时启用两个字幕所有者。示例见包 README。

### 范围与实施决定

- 外挂 SRT/WebVTT 支持 UTF-8、纯文本、平衡 b/i/u、常用/数值实体以及水平 position/align。未知 HTML、字体/voice/ruby、ASS 控制标记明确拒绝。start/end 与视图 Directionality 一致；未宣称实现所有 WebVTT 排版算法。
- 文件/HTTP 流式读取；目录合计最多4MiB、10,000 cue、20,000 span，每 cue 最多512 span/16层标签。原子替换期间旧目录和新目录可共存，预算最多各一份。较新替换（包括不支持格式/策略）、load、stop、dispose 取消旧读取；失败不发布损坏目录。
- platformDefault HTTP 采用30秒总截止、5次重定向、无重试、系统证书信任、identity编码；跨域后凭据永久剥离。TLS 握手期间持有底层 socket 并可关闭。显式非identity请求及 managed policy 拒绝，不能静默改写要求。此选择的代价是 managed 字幕网络仍待实现。
- 本地字幕状态与 native revision 分别管理，公开 state revision 单调。启用时，event revision 指向交付时可观察的公开快照，session/occurredAt 保持原值；不声称是事件起源的 native revision，也不维护无限增长的历史映射。默认路径语义不变。
- 查询仅使用已发布媒体位置，不推测墙钟；暂停/缓冲不会自行前进，seek 立即隐藏并等待 ACK 后的位置快照。代价是显示精度受 `positionUpdateInterval` 限制，不能宣称逐帧同步。
- 字幕在可见视频区域内保持直立，处理 fit/crop/PAR/旋转，忽略指针输入。首次呈现前、结束/失败/stop/dispose 后不显示。受保护源/输出拒绝字幕命令，不读取保护视频像素。

上述裁定冻结于[运行契约](../specs/2026-10-11-subtitle-runtime.md)。独立错误是命令级、脱敏的拒绝；未替 PD-03 决定未来字幕运行故障是否终止视频。TTML、内嵌字幕、ASS/SSA、PGS/VobSub、HDR亮度及三端真机同步仍开放，Task 2 全部和 CAP-SUB 未标完成。

### 验证、失败和复审

新增测试从公开 opt-in/API 缺失的 RED 开始；首轮同时暴露测试夹具 `codedSize` 应为 `encodedSize`，修正后实现基础链路。4/4 文件/控制器/叠层，26/26 真实 loopback I/O 与文本标记用例通过。

扩展生命周期测试首次被 Flutter binding 的 HTTP400 伪响应阻挡；在该测试文件中明确恢复真实 HttpClient，保留失败日志。随后13项中两项失败：dispose 后公开目录未清空（真实缺陷，已修复），预算夹具字符串替换造成零长cue（夹具缺陷，改为直接生成独立时标）。修正后13/13。像素读取首次未置于 tester.runAsync 导致等待；中断该次运行并修正夹具后，四种几何的真实绘制像素通过。四张PNG使用 Flutter Ahem 测试字体，因此显示矩形字形；用于位置/裁切证据，不作为字体审美或真机截图。

首次集中四包回归542/542。一次独立只读复审无Critical，提出两项Important：event/native revision 域错配，以及较新不支持请求未取消旧读取。两项均先用新增用例实际 RED 后修复。RTL start/end 原列Minor，按已声明对齐功能提升为必须修复，两个方向用例 RED→GREEN。另自行补充非identity请求不可被覆盖、SRT内ASS标记不可原样漏出的 RED→GREEN。没有遗留复审项。修复后全部51项定向字幕用例通过；最终集中回归结果和哈希见后续冻结记录。

最终集中命令曾在启动前被磁盘空间耗尽阻挡（shell重定向与here-document均报 no space left on device，未启动测试）。确认恢复约100MiB空间后重试；未删除其他任务数据。全程未启动原生构建、设备、长播放或弱网 ABR；没有更改其源文件、验收门限和工作成果。公开宿主框架渲染与物理设备播放证据严格分开。

最终冻结源码：从仓库根运行 `flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test`，**549/549、0失败、exit 0**（132/222/113/82）；播放器新增51项。最后一版用例额外确认迟到FirstFrame的原始时间与四类事件 payload 保留。静态分析 `yl_player` 与 platform_interface 的 lib/test 全部 **No issues found、exit 0**。未修改既有测试门限。源码、规范、报告及原始日志/PNG指纹见[证据清单](evidence/2026-10-11-subtitle-runtime/manifest.json)。本项使用独立 Git index 和比较更新提交引用，仅包含字幕切片及自身总览追加段，保留其他会话暂存内容。

## 2026-10-11：Task 2 managed 字幕网络策略

用户明确要求接入 managed、验证后提交。继 `8ab86d0` 的真实字幕运行切片，复用现有 `YlNetworkPolicy.managed`，新增每跳 DNS/TCP/TLS/响应头截止、正文无进展截止、有限重试和退避。正文非空块重置 readTimeout；managed 没有总调用截止。platformDefault 的30秒总截止/5跳/零重试保持兼容。

GET 仅重试 socket/timeout/提前关闭及408/429/500/502/503/504；系统信任失败、格式/编码/大小与永久HTTP错误不重试。每次尝试独占新连接及空缓冲，重试从当前URI继续；重定向次数跨尝试共用，跨origin剥离的凭据永久保持剥离。maxRetries 不含首请求。指数退避饱和于上限，Retry-After 合法秒数/HTTP日期优先但不得超过等待上限，非法值回退公式；日期支持三种标准形式并严格验证日历，处理RFC850的50年窗口/跨世纪。详见[策略契约](../specs/2026-10-11-subtitle-managed-network.md)。

取消会关闭当前读取、TLS握手和退避定时器；replace/load/stop/dispose 后不再发起重试或提交过期目录。Stop未ACK时取消可先返回 load.cancelled，ACK后的命令仍是 session.stale；测试显式持有ACK验证两个阶段。终端错误继续脱敏为命令级、retryable=false，保留旧目录，不新增外层重试。

### 实际失败与复审修复

- 起始9项真实 RED（managed 被旧实现拒绝），退避函数用例先因函数缺失失败；初版13项通过。
- 扩展首轮57通过/2失败：HTTP夹具未关闭 bufferOutput，flush未按块交付（类型/长度诊断确认）；另一个用例依赖Stop的微任务顺序。修正夹具并明确ACK阶段，未放宽截止门限。
- 日期RED暴露SDK宽松日历归一化、两位年份解释以及世纪窗口，改为独立严格三格式解析。一次并发 dart fix/format 造成局部编辑损坏和编译失败，已修复并改为顺序变换；`directed-green.log` 是这次失败原始文件，其文件名不代表通过。所有失败/诊断保留。
- 隔离基线 `8ab86d0` 加本轮源码后，74项定向通过。一次独立只读复审提出 Important：Dart将响应头期间的 SocketException 包装为 HttpException，TCP reset 漏重试。新增真实 POSIX SO_LINGER RST 夹具首先失败，再加入只观察原始错误的Socket代理，保持SecureSocket身份并限定当前attempt还原，修复后75/75。原有TLS/非法协议不重试用例继续通过。该复审项只读复核关闭，无遗留Important/Critical。

### 验证隔离与边界

并行会话曾修改公共控制器/SPI，故最初使用 `8ab86d0` 的临时固定副本，仅覆盖本项源码。其直播公共契约提交 `8e11db5` 后，最终副本更新到该提交，再覆盖8份字幕源码/测试；不混入其未提交长播放或弱网工作。本轮无原生构建、设备、长播/弱网ABR执行，也未改这些文件或测试门限。

本切片完成的是已有SRT/WebVTT运行时的managed网络策略；TTML/内嵌/高级及图形字幕、HDR/保护输出、三端真机同步、多音轨与PD-03仍开放，不能关闭整个Task 2或CAP-SUB。最终冻结结果与原始日志指纹见[证据清单](evidence/2026-10-11-subtitle-managed/manifest.json)。

最终冻结命令：从临时副本仓库根运行 `flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test`，**615/615、0失败、exit 0**（135接口/285播放器/113 Apple/82 Android）；本项新增45项。`dart analyze` 检查播放器与接口lib/test，**No issues found、exit 0**。所有8份覆盖源码在测试副本与提交候选中逐字节一致；采用独立Git index及HEAD比较更新，只提交字幕文件和自身总览/变更日志段，保留其他任务未提交内容。

## 2026-10-11：Task 2 TTML 外挂文本加载与渲染

用户授权 TTML 接入、验证后 commit，继续避开长播放和弱网 ABR。以 `bdaf7bc` 为起点，按既有 Task 2 的“冻结 TTML 可实现子集”步骤完成媒体时标、namespace、基础样式和百分比region；采用现有公开 `YlSubtitleFormat.ttml` 和 `enableTextSubtitles`，没有新增 native/Pigeon 协议。具体形式及拒绝边界见[TTML契约](../specs/2026-10-11-subtitle-ttml.md)。

### 实现决定与证据边界

- 新增 xml7.0.1（MIT）和其 petitparser7.0.2 依赖，离线使用缓存制品，锁文件记录包hash。使用惰性XML事件，不构造无界DOM，不解析DTD/外部实体，不下载字体或样式。额外校验XML字符和实体，避免依赖的宽松原样保留行为。
- 支持并行body/div的相对时间及父区间裁切，有限p段落和未定时span、br、默认/保留空白；有界解析继承/引用/链式基础样式。时值转换前检查整数乘法边界，避免溢出变成短字幕。
- TTML输出是解码后的文本片段，不再通过SRT标签解析；转义尖括号和类似ASS控制文字按文本显示。百分比region映射到既有可见视频区域，区域独立流式排版并裁切溢出，保持文字直立。fontSize采用默认垂直cell、Flutter monospace回退；不声称字体度量或完整TTML/IMSC符合性。
- 严格限制输入4MiB、事件50,000、深度32、单元素属性32/单属性4096码元、style/region各128、单引用表16/链深32；继续受目录10,000 cue/20,000 run、单cue16,384码元/512 run及活动64 cue限制。超界/损坏/不支持均脱敏，失败不发布新目录，不替PD-03决定视频存活。
- 选择/off/offset、文件/managed HTTP、重试取消及seek/换源沿用已验收管线。高级时基、timed span、动画、竖排、自定义字体/字号等明确拒绝；内嵌、HDR/DRM和真机同步不计本次完成。该裁定的代价是这些合法高级TTML素材仍需后续切片。

### 失败记录与定向验证

入口3项先实际RED（TTML旧版明确unsupported）。首轮35项14通过/21失败，主要因XML依赖对未加前缀属性也附加默认namespace；按XML规则显式保持未加前缀属性无namespace，修复后35/35。损坏HTTP夹具同步补合法TTML namespace，使其准确覆盖损坏结构而非不支持namespace。

扩展边界43项41通过/2失败：大h偏移整数溢出绕过上限，及精确七天父end与未指定end哨兵混用。两项修正后，与原SRT/WebVTT一并130/130通过。再补HTTP正文取消与迟到完成、解码文字不重复解释、双region独立布局和溢出裁切，新TTML套件49/49。

初次静态检查19条info，括号/字符串风格修复工具已应用17处后因工作区外telemetry文件写权限返回非零；保留真实退出记录，不把该命令标作成功。手动改用XML事件value接口后，再次分析No issues found。期间一次本机命令响应变慢，未动其他任务进程，取消了本任务尚未执行的编辑命令并重跑；没有重复写入。

六张owned像素图使用Flutter Ahem测试字体，呈矩形字形，证明颜色和区域位置/裁切，不是实际设备字体截图。另有两区域溢出像素检查；公开控制器测试使用fake媒体状态，文件和loopback HTTP读取真实执行。全程不运行native/设备/长播或弱网ABR，未修改其源文件/门限。

### 独立复审与修复

一次独立只读复审提出1 Important（XML依赖接纳不完整XML语法）与1 Minor（缓存使style-chain32层限制受声明顺序影响）。后者按实际影响提升为需修复：同一引用图不应因定义排序不同而改变接纳结果，且上限是本项明确承诺；独立128样式上限始终存在，不将此夸大为无界资源漏洞。

新增20项实际失败（其余43通过）：根外文本/CDATA、嵌套或迟到声明、未引用/缺值属性、非法注释、重复/保留namespace、正文CDATA结束符、声明字段，以及顺序不同的长样式链和旧目录保留。增加事件原文的有限词法/边界校验，保留XML依赖负责tokenization/嵌套/namespace；缓存同时存储链深，任何声明顺序执行同一32层上限。修复后TTML70/70，未遗留复审问题；按一次修复规则不再派第二轮复审。

复审未判断的完整TTML/IMSC、native/内嵌/跨Period音轨身份、高级字体/图形、HDR/DRM真机与PD-03仍为P02后续范围，本项不据此宣称完成。另一会话随后提交源解析器工具 `79dbfad`，最终隔离验证副本已纳入该提交，再覆盖本项12份源码/测试/依赖文件，仍排除其未提交长播/弱网内容。

最终固定源码在隔离仓库根执行 `flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test`，**685/685、0失败、exit0**（135接口/355播放器/113 Apple/82 Android）；本项新增70项。播放器与接口lib/test的最终静态分析 **No issues found、exit0**。所有12份覆盖文件与工作区候选逐字节核对；完整源码/依赖/报告、失败日志和PNG指纹见[TTML证据清单](evidence/2026-10-11-subtitle-ttml/manifest.json)。独立Git index及HEAD比较更新只提交本项文件和自身总览/变更日志段，不纳入其他任务暂存或未提交成果。

## 2026-10-11 ASS/SSA 外挂文本加载与渲染

用户明确要求继续 ASS/SSA、验证后 commit，并避开另一会话的长播放与弱网 ABR。本次交付 [Task 3A 有界文本切片](../specs/2026-10-11-subtitle-ass.md)，不将完整 Task 3 或 P02/CAP-SUB 标为完成。

- 接入现有 `YlSubtitleFormat.ass/ssa` 和 opt-in 文本 owner，复用实际 file/HTTP(S)/managed 网络、取消、原子目录、选择/关闭/偏移与媒体状态门禁。
- 支持 UTF-8 ASS v4.00+ / SSA v4.00、显式 PlayRes/WrapStyle 1 或 2、Format 列映射、SSA 对齐与颜色；字体回退/字号/基础样式、颜色与透明度、描边/阴影、脚本坐标及九锚点、Layer 和默认碰撞避让；pos/move/fad 使用媒体位置减字幕偏移，不设动画计时器。
- 字体附件、矢量/clip、卡拉 OK/复杂变换、smart wrapping 0/3、混合同 cue 阴影偏移等明确拒绝。裁定代价：这部分合法高级脚本仍需后续实现，不降级成貌似成功的错误画面。Flutter 字体度量不是 libass/VSFilter 像素符合性承诺。
- 4 MiB、10,000 cue、活动64、单cue16,384码元/512 run及目录20,000 run；ASS parser在创建 run 前消费剩余目录额度。样式/字体身份各128，字号256、描边/阴影16、坐标/分辨率8192与七天时间上限。每cue最多四个随paint释放的TextPainter；fade临时layer裁在可见cue范围，无新增字体/位图常驻缓存。

### 制品、许可与验证范围

[制品审计](evidence/2026-10-11-subtitle-ass/artifact-audit.json)记录6份实际 Android/Apple 二进制、两份构建脚本与两份 FFmpeg 9.0.1 lock 的 SHA256；脚本均禁用自动探测/avfilter且未启用libass，仅显式列出音视频模块。libass（ISC许可）作为后续完整渲染候选，参考0.17.4解析行为；本切片未新增该库或其他包/原生依赖。不会把上游能力记为现有制品能力。

owned Ahem 样本在固定媒体时点手工推导像素框，验证9锚点、移动/淡出、独立颜色描边/阴影、层级/重叠、旋转/PAR/aperture裁切、字体回退。三张PNG证明坐标/颜色/透明度，不是真机字体外观认证。文件和loopback managed HTTP是真实I/O；首帧/暂停/偏移/seek/off/换源使用现有fake平台。未运行原生构建、设备、长播或弱网ABR；HDR/DRM、内嵌、PGS/VobSub、三端实际字体效果及PD-03仍开放。

### 失败、复审与最终证据

1. 入口4项RED均因旧runtime拒绝ASS/SSA；首轮44通过/1失败，修正clip被误认成颜色标签后的错误分类。
2. 画面首轮53通过/1失败：分别淡出fill/outline造成边缘透色。改为cue级淡出合成后54通过，第一次四包739通过（此次为共享工作目录；最终下述验证在隔离副本完成）。
3. 补9锚点与阴影后18通过/1失败：Flutter默认阴影没有描边扩张。显式shadow outline/fill绘制并限制同cue统一偏移，保持四个painter上限。
4. 一次独立只读复审提出3 Important（run预算分配后才检查、move零/零时标、命名reset默认值）及1 Minor（CRLF双计）。CRLF按输入预算契约提升为需修复；5项RED（含混合shadow拒绝）后统一修正，定向70/70。剩余目录预算测试另在隔离副本移除传递参数，真实RED证明它可区分分配前拒绝和晚发现不支持内容；恢复最终代码后进入全套验证。[复审记录](evidence/2026-10-11-subtitle-ass/review.md)无遗留问题，不再进行第二次复审。

最终基线 `ffc46826d0fbfc955bd94530b430ae777625e4fa`，隔离副本只覆盖本项11份源码/测试；排除另一会话未提交内容。仓库根运行 `flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test`：**755/755、0失败、exit0**（135接口/425播放器/113 Apple/82 Android），本项新增70项。播放器和接口lib/test静态分析 **No issues found、exit0**；所有候选代码与验证副本逐字节核对。

[证据清单](evidence/2026-10-11-subtitle-ass/manifest.json)保留原始成功/失败日志、PNG、审计/复审和源码文档指纹。使用独立Git index及HEAD比较更新，仅提交本项与自身总览/CHANGELOG段，不夹带另一会话已暂存或未提交内容。

## 2026-10-11 PGS 外挂位图加载与渲染

按用户指示继续 Task 3B，复用 `enableTextSubtitles: true` 和 `YlSubtitleFormat.pgs`，接入实际 SUP 文件/managed HTTP(S) 加载与 Flutter 位图合成。具体支持与拒绝边界见 [PGS 契约](../specs/2026-10-11-subtitle-pgs.md)。不改公开 SPI、Pigeon、原生实现或依赖，不触碰长播放/弱网 ABR。

### 实现与裁定

- 二进制绕过 UTF-8/文本标签。解析 SUP framing、90 kHz PCS PTS/32-bit rollover、完整 display set、分段 ODS 与严格逐行 RLE；部分 palette 更新保持其他颜色，输出 premultiplied RGBA。窗口/源裁剪、双对象顺序重叠、清屏及同 PTS 替换均有测试。
- 沿用媒体位置减偏移查询；最终非空 display 保持到下一次清屏/变化或 session 结束，受既有七天上限约束。强制标志保留，选中轨道时显示其全部对象。普通视频 fit/PAR/rotation 保持字幕直立，cover 使用实际可见源区域；不通过 OCR 或文字替代图形。
- 4 MiB encoded / 10,000 cue / 20,000 text run 的既有目录限制保留；PGS 独立限制每目录 64 MiB 展开 RGBA，剩余额度逐文件传入并在分配前检查。每文档 50,000 segment，单对象 4,194,304 像素、epoch indexed cache 16 MiB、64对象/8调色板/2窗口/2引用。老目录和候选各有预算，失败替换保持老目录。
- 仅当前画面创建最多两张引擎图片；跨 view 的异步在途任务最多两个，排队任务随替换合并，迟到结果释放。稳定时间/几何重建复用图片，seek/off/换源/卸载释放所属 handle。多个挂载 view 各自持有图片；不把这些字节预算表述为总 RSS 上限。
- 接纳显式 WDS 重绘、空 PCS 清屏和 palette-only 重着色；cache-only 非空重绘、palette-only ODS/WDS 等语义明确拒绝。裁定代价：部分合法高级 SUP 仍需后续 decoder 语义；超预算大轨道需要未来流式/预算扩展。本项不是完整 Blu-ray/native 认证。

### 审计、失败记录与验证范围

[制品审计](evidence/2026-10-11-subtitle-pgs/artifact-audit.json)逐一复核前次六份 Android/Apple 二进制、两份构建脚本与两份 FFmpeg 9.0.1 lock 的 SHA256 均未变。构建配方未启用 SUP/PGS 模块；此切片为原始 Dart parser 与 Flutter compositor，不将上游支持冒充现有 native 能力，没有新增包、借用样本或许可负担。

入口先 0通过/3失败（旧 runtime 拒绝 PGS）。首轮验证发现 RGBA 需要预乘 alpha；后续 Skia 像素测试发现同步 raw-image API 虽存在但未实现，改用可移植 ImageDescriptor/Codec 异步路径，并增加在途上限和迟到释放测试。夹具同时修正：客户端取消后的服务器关闭等待、601整数取整/旋转采样坐标、双对象异步回调间的 widget pump、资源错误码名称。未放宽既有测试时间门限。

定向 58/58：44解析、4实际 I/O/目录资源、10像素与生命周期。三张固定时点 PNG 使用 owned 小型 SUP 与手工推导坐标/颜色，全图检查调色板/半透明/清屏；另验 cover/PAR/rotation、双对象 alpha 重叠、句柄复用/释放、引擎失败脱敏和频繁重挂载的两个在途任务上限。公开控制器生命周期用 fake 媒体事件，文件及 loopback HTTP 真正执行。没有原生/设备/长播/弱网 ABR 验证，HDR/DRM、内嵌、VobSub、PD-03 与 P02/CAP-SUB 仍开放。

### 独立复审与兼容性修复

一次 fresh-context 只读复审提出 1 Important、无 Critical/Minor：有效 Alignment 将视频部分移出视口时，位图源区域未对应 destination 裁切，造成压缩。左/右/上/下四项像素回归先实际 0通过/4失败，改为保留完整拟合 destination、再将相交区域映射回 source，PGS 定向 **62/62**。仅一次修复，无第二轮复审；所有未判断范围与裁定代价见[复审记录](evidence/2026-10-11-subtitle-pgs/review.md)。

四包首轮在既有 runtime 的“不支持格式仍取消旧请求”用例暴露夹具遗漏：PGS 变为支持后换成 VobSub，但缺少契约要求的 companionSource，故在参数校验阶段返回 ArgumentError 而非进入 runtime。补齐 idx/sub 配对，使它继续测试原有不支持能力取消逻辑；未改公共校验或生产取消行为。首轮失败及主动中止后的 Flutter sink shutdown 错误如实保留在 four-packages-first.log，最终重新运行固定候选。

### 最终冻结验证

基线 `1a20e5dc488b0f4a129db8ab4b26b5f7e3f5f16c`，隔离副本覆盖本项11份源码/测试，排除另一会话未提交内容。仓库根执行 `flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test`：**817/817、0失败、exit0**（135接口/487播放器/113 Apple/82 Android），本项新增62项；播放器与接口lib/test的最终静态分析 **No issues found、exit0**。修正旧格式夹具后的23项 runtime 兼容性测试也全部通过。

[证据清单](evidence/2026-10-11-subtitle-pgs/manifest.json)保留源码/依赖/文档指纹、完整成功/失败日志、三张像素图、制品审计与复审裁定。所有11份候选源码与验证副本逐字节一致；独立Git index及HEAD比较更新只提交字幕切片和自身总览/CHANGELOG段，不夹带另一会话修改。无遗留复审问题；完整 Task3/P02 尚未完成，继续保留执行账本。
