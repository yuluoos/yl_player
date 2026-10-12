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

## 2026-10-11 VobSub 外挂配对加载与渲染

按用户指示继续 Task3C：`enableTextSubtitles: true` 与既有 `YlSubtitleFormat.vobsub` 接入真实配对加载、DVD 位图解析和 Flutter 合成；`source` 明确为 .sub，`companionSource` 为 .idx。不猜文件名或获取外部隐式资源。精确支持边界见 [VobSub 契约](../specs/2026-10-11-subtitle-vobsub.md)。当前原生/Pigeon/SPI 与依赖不变，不触碰长播放/弱网 ABR。

### 实现、预算与范围裁定

- 严格 UTF-8 v7 索引、size/16项RGB palette、id/index、timestamp/filepos、delay/default language。一个公开目录项按调用方语言唯一匹配或 langidx/首项选择一个子流；有歧义或找不到显式语言时明确拒绝。索引时间为主时钟，不采用 PES PTS 改写时间。
- MPEG-2 pack/PES、结构性PTS/DTS、填充/系统包、private stream 子流分片重组；一个线性扫描建立包位置映射，验证所列子流引用。DVD双场1..4nibble RLE、行尾填充/字节对齐、奇数高度、反向存放的场地址、palette/4bit contrast、坐标和start/forced/stop控制。palette/alpha/position的后续控制块按媒体时刻拆分画面。
- 共享 PGS 已验收的不可变 RGBA 表示、几何裁剪与异步图片队列，保留内部历史类型名，错误消息改为通用 Subtitle image。无额外 GPU 目录缓存、定时器或独立解码队列。首帧、暂停、偏移、seek/off/换源的门禁沿用现有 owner。
- `.idx` 和 `.sub` 各自执行其来源的 managed 策略，共用取消令牌与4MiB encoded目录额度，任一失败不发布。PGS/VobSub共用64MiB展开RGBA，分配前消费剩余额度；bitmap≤4,194,304像素、canvas≤8192、SPU≤65535 bytes、索引≤50,000行/每行2048码元、条目≤10,000、PS≤50,000 segments、控制命令≤50,000/每SPU≤256序列。旧/候选目录独立有界；这不是总RSS或多view图像总量保证。
- 本次选择原始 Dart 路线；MPEG1/rawSPU/HD、压缩包、区域CHG_COLCON与非中性索引效果等拒绝。缺失stop时只保持到下一索引项或七天界限，负delay裁到零。代价：部分合法高级DVD素材和大轨道仍需后续实现；不将这些限制默认为完整VobSub/光盘认证。

### 审计与定向证据

[制品审计](evidence/2026-10-11-subtitle-vobsub/artifact-audit.json)重新核对六份Android/Apple二进制、两份构建脚本和两份FFmpeg9.0.1 lock，指纹与PGS阶段一致。当前配方没有DVD字幕codec，本切片不依赖该原生功能；无新增库或借用样本。FFmpeg n8.0 mpeg.c/dvdsubdec.c用于格式对照，未复制链接代码或资产。

入口先0通过/2失败（既有runtime拒绝VobSub），接入后2/2；解析边界首轮49/49。再加入两份资源取消、配对输入预算、手工全图像素、公开生命周期及共享渲染回归，95/95（含既有23 runtime与14 PGS overlay）。扩展PS结构/巨大bitmap/语言歧义/字段顺序/跨文件RGBA后，新VobSub定向65/65。另在隔离副本暂时移除剩余预算传递，跨文件测试实际RED，恢复候选后才进入最终验证。初次分析17条括号风格info、扩展测试另1条，均已修正，真实日志保留。

三张PNG按1000/1512/2024ms捕获，owned 4×3 DVD样本的顶/底场、RGB/alpha与位置均手工推导并全像素比较；并非真机截图或光盘符合性认证。实际文件和loopbackHTTP执行；公共媒体事件用fake平台。没有native构建、设备、长播或弱网ABR；HDR/DRM、内嵌、外接重连、PD-03及整个Task3/P02仍开放。

### 独立复审与一次修复

一次 fresh-context 只读复审指出2 Important：常规dvdauthor输出的P-STD PES扩展、SPU奇数字节长度末尾的单个0xff对齐。两项均据实际producer代码确认，补精确结构支持，仍拒绝扩展截断/错误marker/任意尾随字节。另有首行跳过2048码元限制的Minor，按本项资源契约一致性提升为需修复；原4MiB总限一直有效，不夸大为无界内存问题。

首行独立测试0通过/1失败；合并回归54通过/7失败，随后一次修正三项。复审未判断范围及裁定代价完整记录在[复审记录](evidence/2026-10-11-subtitle-vobsub/review.md)，并把共享RLE场、PXD间隙、同一pack同子流多个完整SPU等严格接纳限制写入契约。没有遗留minor或第二轮复审。

### 最终冻结验证

复审修复后新VobSub **73/73**（61解析/7实际I/O与资源/5画面及公开生命周期），无遗留问题。最终隔离基线 `1a4c674fafb82c308c2e6cc94a75057c8131a6cf`，只覆盖本项12份源码/测试；另一会话新提交仅文档/证据已纳入基线，未提交长播/ABR仍排除。

仓库根执行 `flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test`：**890/890、0失败、exit0**（135接口/560播放器/113 Apple/82 Android），本项新增73。播放器与接口lib/test静态分析 **No issues found、exit0**。未放宽任何既有门限。

[证据清单](evidence/2026-10-11-subtitle-vobsub/manifest.json)保留完整原始日志、三张PNG、制品审计、复审裁定及源码/文档/依赖指纹。12份候选源码与隔离验证副本逐字节一致；独立Git index及HEAD比较更新仅提交本项文件与自身总览/CHANGELOG段，保留另一会话未提交内容。完整Task3/P02仍未完成，执行账本继续保留。

## 2026-10-11 本地 Matroska 内嵌字幕发现、选择与渲染

继续已授权 P02 字幕切片，在 `enableTextSubtitles: true` 下新增
`session.discoverEmbeddedSubtitles()`，从**当前已提交会话的本地 MKV** 实际读取
UTF8/SRT、ASS/SSA 轨道，使用 `mkv:<TrackUID>` 选择并由既有 `YlPlayerView` 合成。
这是首个内嵌容器切片；网络、其他容器/内嵌位图、原生字幕回调仍未实现，不能据此
关闭完整 P02/CAP-SUB。精确边界见[内嵌契约](../specs/2026-10-11-subtitle-embedded.md)。

### 行为与裁定

- 读取器按元素边界随机访问，跳过音视频载荷，严格验证父边界、TrackUID/TrackNumber
  唯一性、时间戳与资源预算。支持未知长度 Segment，拒绝未知长度子元素；最多128条
  总轨道、32条启用字幕、5万 Cluster、200万元素、64MiB读取量及30秒协作式I/O期限。
- 容器时间戳、BlockDuration/DefaultDuration、CodecDelay 决定 cue 时段；保留微秒精度。
  UTF8直接形成cue，避免文本注入伪SRT事件；ASS/SSA复用已有样式解析与合成，按ReadOrder
  排序并使用精确容器时刻，不把时间舍入回ASS文件的百分秒。
- 外挂替换/清空保留内嵌项，重新发现保留外挂项；同源原子发布、跨来源ID冲突拒绝。
  选择依据UID，消失后关闭，不按同语言另选。内嵌与外挂共用4MiB输入、1万cue、2万run和
  64MiB位图目录预算。取消后旧扫描不能发布，文件扫描串行释放描述符；新Load、seek、
  off、Stop与Dispose沿用字幕媒体时钟门禁。
- 范围裁定：通过现有Dart owner先完成本地MKV文本链路；没有添加原生桥接/解码路径。
  代价是网络/其他容器和native字幕通道需继续实现；启用但不支持的codec会拒绝整个候选，
  保留旧目录，不静默声称支持。字幕错误独立于视频状态，PD-03不在此决定。

### 验证与复审

真实文件入口先0/1失败（缺发现方法），接入后1/1；容器扩展36通过/1失败，修复普通
视频BlockGroup的重复ReferenceBlock后通过。独立host FFmpeg封装的owned小型MKV含实际
MPEG-4视频与双SRT轨，ffprobe记录真实包时刻/语言/forced标记；该CLI仅用于夹具生成，
不加入运行时依赖。Flutter widget使用真实提取结果验证显示、off/seek清屏和卸载，
视频平台状态由fake backend驱动，**不是实机播放或native字幕同步认证**。

新Dart能力导致原生枚举对等测试先73通过/4失败，更新Dart-only排除集合后定向86/86；
没有扩大原生广告能力或改动Pigeon。首次完整四包940/940，分析清洁。

一次独立只读复审提出1 Important：显式ReferencePriority=0被误拒绝，依据RFC默认值
接受零并继续拒绝非零。另1 Minor是32条启用字幕后出现禁用项仍触发上限，按已承诺的
启用轨道计数规则重新定级为需修复。两项回归实际52通过/2失败，一次修复后**54/54**。
无遗留minor，无第二轮复审；全部未判断范围、裁定及代价见[复审记录](evidence/2026-10-11-subtitle-embedded/review.md)。

最终隔离候选基线 `38732230f4adbbd76e5ac6aec6298930a7965d9e`，只覆盖本项17份源码/测试/二进制
夹具；此前基线新增的其他会话提交仅文档/证据，已核对无源码交集并同步。根目录执行
`flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test`
为 **944/944、exit0**（135接口/614播放器/113 Apple/82 Android，新增54项）。播放器和接口
lib/test在隔离候选中的分析 **No issues found、exit0**。未放宽既有测试门限。

[证据清单](evidence/2026-10-11-subtitle-embedded/manifest.json)保存成功/失败日志、ffprobe、制品审计、
复审裁定及指纹；17份候选与验证副本逐字节一致。六份生产原生二进制、两份配方和两份
FFmpeg锁与VobSub提交一致；无native构建/设备/长播放/弱网ABR运行。独立Git index与HEAD
比较更新仅提交本项文件及自身总览/CHANGELOG段。整个P02仍开放，执行账本保留。

## 2026-10-11 网络 Matroska 内嵌字幕与 managed 策略

沿用 `discoverEmbeddedSubtitles()`，当前 HTTP(S) MKV 可发现 UTF8/ASS/SSA，按 TrackUID 选择并复用既有 Flutter 渲染。既有本地与外挂行为保留；失败或取消不替换旧目录。完整接纳规则见[网络 Matroska 契约](../specs/2026-10-11-subtitle-network-matroska.md)。本项不改原生桥接、依赖、长播放或弱网 ABR。

### 传输与资源边界

- 元素读取器通过16KiB对齐窗口访问远端，128窗口 LRU（2MiB）；跳过音视频载荷，不进行完整文件回退。严格单段206、Content-Range、固定已知总长和强ETag；首个完整响应固定最终URI，后续 If-Match 并再次核对标识/总长，资源变化、multipart、压缩、短体/多体均拒绝。
- 复用 managed socket/逐跳超时/读取空闲超时/重试日期语义；一次扫描共享重试和重定向额度，跨源剥离凭据不可恢复。请求次数≤4096、实际响应进度≤64MiB，重试及部分响应也消费额度。单次拼接≤256KiB以兼容合法 CodecPrivate。原有解析与目录预算继续生效。
- managed 无额外总期限；platformDefault 保留30秒扫描期限与不重试行为。换源、Stop、Dispose、外挂替换取消所属网络扫描并清理缓存；错误脱敏，字幕失败不进入视频失败状态。
- 服务器无强ETag或Range支持明确拒绝；条件请求头冲突在I/O前拒绝。版本固定只保证字幕扫描内部一致，不能保证另一路native视频请求的版本。预算可能限制大文件/稠密文件，本项不是任意容器、完整Matroska认证或总RSS保证。

### 验证与复审

入口实际 RED 0/1（原先拒绝网络）→首轮 GREEN 40/40（含既有managed/retry回归）。扩展48通过/2失败定位合法大CodecPrivate与multipart接纳，修复后50/50；公开生命周期和TLS加入后58/58，4096真实请求限额加入后新增测试合计**59/59**。

51项传输/容器覆盖真实loopback HTTP、稀疏5MB跳读、ASS/SSA样式、强校验器变化、缓存淘汰、各重试状态/终止状态、共享重试/重定向额度、跨源凭据、超时/取消及请求硬限。6项公开会话测试验证发现、选择、forced/off、偏移/seek渲染与换源/停止/销毁等取消；2项实际TLS验证不可信证书不重试、可信HTTPS发现及拒绝降级。成功TLS仅在该测试文件隔离VM信任owned证书，生产信任策略未改。视频事件采用fake backend，网络与字幕读取/合成实际执行，不是设备播放认证。

一次独立只读复审**无Critical/Important**；1条Minor建议补合法chunked206正向成功用例，按计划保留后续，现有短体/超长体拒绝已覆盖。无生产缺陷修复或第二轮复审；全部未判断范围、裁定和代价见[复审记录](evidence/2026-10-11-subtitle-network-matroska/review.md)。

最终四包在隔离副本执行 `flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test`：**1003/1003、0失败、exit0**（135接口/673播放器/113 Apple/82 Android，新增59）。播放器与接口lib/test分析 **No issues found、exit0**。未放宽既有测试时间门限。

测试基线 `305af43f48fbfa50f4af2ebd7b0960fc91bb7e14`；提交前另一会话推进至 `f1406eca3b2989491376e1b6ff671f8220cc828b`，差异仅P05文档/证据，已核对无源码交集并同步到隔离副本，不重复整套验证。9份候选源码/测试与已验证副本逐字节一致。六份生产二进制、两份配方、两份FFmpeg锁未变。

[证据清单](evidence/2026-10-11-subtitle-network-matroska/manifest.json)保存完整成功/失败日志、制品审计、复审记录与候选/依赖指纹。独立Git index与HEAD比较更新仅提交所属文件与自身总览/CHANGELOG段，保留另一会话所有未提交内容。完整Task3/P02仍开放，执行账本保留；本次无native构建、设备、长播或弱网ABR验证。

## 2026-10-11 MP4 内嵌 tx3g 发现、选择与渲染

继续用户指定 P02 切片，当前文件或 HTTP(S) MP4 通过同一个 `discoverEmbeddedSubtitles()`
发现 `tx3g / mov_text`，以 `mp4:<Track ID>` 选择并在 Flutter 字幕层合成。选择/off/偏移、
seek和换源门禁沿用现有 owner，失败保留旧目录/选择且不改变视频失败状态。严格范围见
[MP4 契约](../specs/2026-10-11-subtitle-mp4.md)。本次不改原生桥接/公开enum，不占用长播放、
弱网ABR或并行source-resolver清理工作。

### 实现与范围裁定

- 非分片 MP4 的 moov/mdat 可前后排列；32/64位box、stco/co64、stsz/stz2、stsc多chunk/描述、
  stts/ctts和简单elst编辑列表决定样本时刻。样本必须在本文件mdat内，重复ID、表数量不符、
  越界/重叠引用拒绝。媒体时间用整数比例组合后换算微秒，空文本间隙不生成cue。
- 严格UTF8或带BOM的UTF16，纯文本runs防止HTML/SRT/ASS二次解释；默认/styl的b/i/u、
  RGBA、字体回退和字号、水平对齐合成。字号为Flutter logical pixel，背景作为文本底色，
  不宣称QuickTime字体/轨道几何一致。按Apple定义，仅0xC0000000标记整轨forced；不会自动选轨。
- 公共format使用既有srt表示归一化标准文本，不声称原始tx3g编码是SRT；具体容器身份为mp4。
  本切片选择Dart解复用而非新增原生桥接，代价是fMP4、wvtt/stpp、旧MOV text、加密/CEA、
  per-sample forced/高级布局和复杂编辑仍待实现。未完成整个P02/CAP-SUB、PD03或设备验收。
- 所有网络读取复用既有managed Range读取器；强ETag/固定总长、If-Match、单段206、共享
  重试/重定向/凭据规则、超时/取消/字节及请求上限实际执行。不能扩大原生视频的managed
  支持范围；字幕扫描一致性不代表独立视频HTTP请求版本一致。
- box≤200000、总轨≤128/字幕≤32/每轨描述≤32、样本/chunks/time rows≤20000；单次读取
  ≤256KiB、总读取≤64MiB、原始字幕样本≤4MiB、每cue≤16384码元、每sample≤1024style，
  保留runs≤20000。目录既有4MiB归一化输入/10000cue/20000runs/64重叠限制继续执行；
  不是进程RSS或任意大型MP4保证。

### 验证过程

实际文件入口先0/1失败（subtitleUnsupported），接入时真实文件读出的固定长度List不能
removeLast，改为有界截取后1/1。首轮解析47通过/1失败：独立FFmpeg样本带默认不透明黑背景，
过严接纳条件暴露缺口；补实际run背景色后48/48。扩展70通过/3失败包含编辑时间1微秒误差、
stss遗漏验证及EOF测试夹具写错size位置；修复前两项和夹具后73/73。

网络测试首次写错参数名responseHeaderTimeout，触发测试编译失败与关联compiler退出；改用
已有connectTimeout，生产网络策略没有改动。Apple官方flags核对发现初始夹具把some-forced
误当all-forced；先观察该误判的失败用例，再修复为0xC0000000并拒绝不完整flags组合。
格式化后首次分析13条style info、后续2条，均已修正；原始日志如实保存，未放宽既有超时门限。

本项75项测试：57解析/边界，1真实文件入口，11真实HTTP managed/故障/稀疏跳读，6公开会话
选择/渲染/偏移/seek/取消。5MB稀疏容器不会完整下载；支持合法chunked206（补上此前网络
Matroska复审建议的共用读取器正向证据）。独立host FFmpeg用自有黑视频与SRT封装1734字节
MP4，ffprobe记录Track ID2、语言eng及1.000–2.500/3.123–4.567秒，样式由源文本手工确定。
该CLI仅用于生成夹具，没有加入运行时依赖；字幕读取和Flutter合成实际执行，视频backend为fake。

首次四包隔离回归 **1078/1078、0失败、exit0**（135接口/748播放器/113Apple/82Android），
播放器与接口lib/test静态分析 **No issues found、exit0**。六份生产二进制、两份配方与两份
FFmpeg lock指纹与网络Matroska阶段相同。本次无native构建、设备、长播放或弱网ABR验证。

最终复审裁定、冻结候选与提交证据记录在本节后续及[证据清单](evidence/2026-10-11-subtitle-mp4/manifest.json)。

### 最终复审修复与冻结验证

一次fresh-context只读复审：Critical0、Important1、Minor0。发现CRLF在样式边界分开后被
各段重复归一化，多出空白行；执行者回归实际1通过/2失败，改为保留原scalar下标并跨run折叠
CRLF后，新增MP4 **78/78**（60解析/1文件/11网络/6公开生命周期）。无遗留Minor，无第二轮复审；
复审未判断范围的全部裁定与代价见[review.md](evidence/2026-10-11-subtitle-mp4/review.md)。

最终隔离候选基线 `27b0a4117b085c350d9a2231cba6f5448abdea49`：原基线3eb2d39后另一会话
提交仅P05文档和独立source-resolver测试/脚本，核对与12份所属源码/测试/二进制夹具无交集，
已同步基线后执行最终验证。根目录命令：

```
flutter test --no-pub --concurrency=1 packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test
dart analyze --suppress-analytics packages/yl_player/lib packages/yl_player/test packages/yl_player_platform_interface/lib packages/yl_player_platform_interface/test
```

最终 **1081/1081、0失败、exit0**（135/751/113/82；本项新增78），分析 **No issues found、exit0**。
12份所属候选与实际测试副本逐字节匹配；source MP4由host FFmpeg8.0.1生成，六份生产原生二进制、
两份配方及两份FFmpeg9.0.1 lock未变。没有依赖新增，不混淆host生成器和生产制品版本。

完整成功/失败日志、独立ffprobe/原始SRT、制品hash、复审和源码/依赖/文档hash见[manifest](evidence/2026-10-11-subtitle-mp4/manifest.json)。
使用独立Git index和HEAD比较更新，仅提交所属文件及自身总览/CHANGELOG段，其他未提交工作保留。
整个Task3/P02继续开放，执行账本继续保留；仅本项可提交，不据此关闭native/HDR/DRM/设备/PD-03。

## 2026-10-11 MP4 内嵌 WebVTT（wvtt）

继续用户授权的下一字幕项，沿用当前会话 discoverEmbeddedSubtitles/选择/Flutter overlay，
支持本地与 HTTP(S) 非分片 MP4 wvtt。公共轨格式使用既有 webvtt；tx3g 和 wvtt 可在不同轨
共存，同轨混合 codec 描述显式拒绝。按 Track ID 区分同语言轨，不改变公开桥接和枚举。
具体接纳、边界和成本见 [wvtt 契约](../specs/2026-10-11-subtitle-mp4-webvtt.md)。

- 必需 vttC 配置，vttc 内 payl/iden/sttg/ctim，唯一空 vtte 清屏；sample 内多 cue 保留顺序。
  stts/ctts/elst 的媒体时间为准，ctim 不覆盖时间，同 ID 的相邻 sample 不去重。直接构建
  cue，payload 空行/时间箭头不会注入额外事件。UTF8、CRLF、大小和重复字段均严格验证。
- 复用基础 b/i/u/实体，外置与内嵌 WebVTT 共用水平 align/position 解析；同时验证实际
  Flutter 文本样式和 25% 水平位置几何。高级 CSS/region/voice/class/ruby/karaoke、
  line/size/vertical，以及 fMP4/stpp 仍不支持；不是任意合法 wvtt 的互通性保证。
- 未修改网络读取器；所有读取仍执行 managed 单段206、强ETag/总长/If-Match、共享
  重试/重定向/敏感头剥离、超时/取消及缓存/请求/字节预算。失败保留旧目录与选择，
  source replace/stop/dispose/外置目录操作隔离迟到结果。
- sample≤64 cue、每 cue/config≤8子box；payload/config≤16384码元，ID/settings/label
  ≤1024。跨轨保留 packet≤10000；与既有样本/读取/4MiB目录输入/64活动cue限制共同执行。

### 验证过程

真实文件入口先0通过/1失败（原实现 subtitleUnsupported），接入后连同旧 MP4/文本解析
回归116/116。扩展测试初次18通过/1加载失败为测试构造括号遗漏，修正后68/68；静态分析
初次包含同一编译问题与6条风格提示，已修复并保留原日志。新增双轨10112 cue 回归实际
0通过/1失败，暴露逐轨预算不足；改为 parser 跨轨计数，扩展定向 **70/70**。

本项52解析/边界、1真实文件、11真实HTTP、6公开会话/Flutter测试，共70项。包括手算
vttc/payl字节、编辑/ctts/同名分段、多个cue、空cue、清屏、UTF8与字段/box/配置边界、
64活动cue和10000跨轨总量。5MB稀疏HTTP容器验证跳读，后续range重试/凭据、跨源剥离、
版本变化、完整200/403拒绝、合法chunked206与响应头超时实测。

测试数据为手写 owned fixture；没有 wvtt 独立生产器证据。原有独立FFmpeg tx3g夹具仍在
回归中，不把它误报为 wvtt 独立互通性验证。字幕IO/解析/Flutter合成实际执行，视频后端
为fake；无native构建、真机、HDR/DRM/PD-03、长播放或弱网ABR验收，无依赖新增。

首次隔离四包 **1151/1151、0失败、exit0**（135接口/821播放器/113Apple/82Android；新增70），
播放器及接口lib/test分析 **No issues found、exit0**。六份原生二进制、两份构建配方及两份
FFmpeg lock逐项重新hash，与前项相同。最终复审与冻结见下文及
[证据清单](evidence/2026-10-11-subtitle-mp4-webvtt/manifest.json)。

### 最终复审与提交边界

一次 fresh-context 只读复审：Critical0、Important0、Minor1。Minor 是 wvtt 内层 box
尚未计入结构 walker 的200000汇总计数；局部子box/样本/4MiB原始输入仍使工作有界，
未发现错误发布或无界分配。执行者保留Minor等级并按既定流程后续处理，新契约明确实际
预算边界。另有非阻塞建议：设置接受表可加强逐项layout字段断言；已有25%位置实际几何
证据，此诊断增强也留待后续。所有未判断范围的执行者裁定见
[review.md](evidence/2026-10-11-subtitle-mp4-webvtt/review.md)，未安排第二轮复审。

最终候选基线 `a66cc3abde06a3e7485cd805d2072d1fa2686564`；格式化后11份所属代码与测试
逐字节匹配隔离副本。最终命令、结果、制品与源码/依赖/文档hash冻结在manifest；使用
独立Git index和HEAD比较更新，本次总览/CHANGELOG仅加入自身段落。另一边长播放、弱网
ABR及readiness未提交改动不纳入本次提交；不把整个Task3/P02标记完成。

最终隔离验证：四包 **1151/1151、0失败、exit0**（135/821/113/82），播放器/接口 lib/test
静态分析 **No issues found、exit0**。复审无阻塞项，保留1项Minor和1项测试增强建议。

## 2026-10-11 MP4 内嵌 TTML（stpp）

继续用户指定的下一字幕项，在既有非分片 MP4 和 TTML 运行时接入stpp；本地/HTTP(S)
来源、Track ID选择、实际文本/百分比region合成均使用当前字幕owner。公开格式复用ttml，
不同codec可分轨共存；单轨多描述不能混用codec。网络生产读取器没有改动。

### 实现与边界

- stpp三项NUL结尾UTF8元数据严格有界，要求TTML namespace/空辅助资源，仅支持可选
  btrt；schema位置不访问网络。每sample独立XML，现有DTD/实体/namespace规则继续执行，
  外部字体/图片/辅助子样本不加载。
- 核对2022时间修订后，明确按composition轴解析TTML，裁切sample再应用简单编辑；
  绝不加sample起点。组合整数比例后舍入微秒，避免空白延迟和媒体起点分别舍入误差。
  未声明end的段落受sample边界约束，外置TTML有限end要求不变。
- 文档局部region/style/ID隔离，重叠sample中的同名region不会错误合并。纯文本runs与
  region直接进入目录；空文档/编辑外内容的原始字节仍与外挂共享4MiB目录预算。
  单sample256KiB、XML深度/事件/样式和现有MP4/目录cue/runs/活动cue限制继续执行。
- managed单段206/强ETag/总长/If-Match、共享重试/重定向/凭据、超时/取消/请求与字节预算
  复用原路径；失败原子保留旧选择/目录，换源/stop/dispose/外置操作屏蔽迟到结果。
- 只承诺既有TTML文本/样式/百分比区域子集；cell字号/字体资源/图像/高级profile/timed
  span/非media时间基、fMP4/HLS/DASH等仍拒绝。详见[stpp契约](../specs/2026-10-11-subtitle-mp4-ttml.md)。

### 验证过程

真实文件入口先0/1失败 subtitleUnsupported。首次接入回归52通过/2失败：命令误写不存在
的ttml_parser_test，以及测试误要求已解码文字只有一个run；改正确文件名与全部run样式断言。
扩展首次74通过/3失败，包含新测试误用fixture不存在的movieScale参数及随之产生的compiler
加载失败，以及区域几何预期误用整个viewport而非letterboxed视频aperture。修正夹具和
可见区域预期后115通过/2失败，均为测试未遵循既有TTML结构子集（要求body/div/p，非法
结构分类unsupported）；保持生产解析语义，修正测试。连同既有TTML回归120/120通过。

host FFmpeg8.0.1独立生成6107字节owned黑视频+两条SRT的stpp；ffprobe为Track ID2，
XML sample0–4.567秒、文档cue1.250–2.500/3.123–4.567秒。该encoder自带cellResolution、
16c字号和字体/overflow，超出现有TTML子集，测试明确拒绝。首次该负向测试路径定位错误
导致63通过/1失败，修正根目录夹具定位后，本项 **64/64**（45解析边界/2文件预算/11HTTP/
6公开会话与Flutter）。不将独立负向样本当作正向生产器互通性证据。

正向覆盖手写XML/BMFF、实际文件和真实HTTP；包括非零sample绝对时间、ctts、编辑/精度、
重复文档、无限段落裁切、空文档清屏、文档作用域、跨轨10000cue、64重叠及共享原始字节
预算，HTTP稀疏跳读/重试/凭据/版本/200与403拒绝、实际样式及letterbox区域几何、seek/
off/offset和取消。视频backend为fake，无native构建/设备/HDR/DRM/PD-03/长播放/弱网ABR
验收；未增加依赖，10份原生制品/配方/lock重新hash未变。成功与失败日志均保存。

初始基线896e471后另一边提交ede8e48仅6份P05文档/清单，与本项14份代码/测试/夹具无交集，
隔离副本已同步提交内容后验证。并行工作区的benchmark脚本改动不进入候选或提交。
最终复审和冻结证据见本节后续与[manifest](evidence/2026-10-11-subtitle-mp4-ttml/manifest.json)。

### 最终复审与冻结

一次fresh-context只读复审：Critical0、Important0、Minor0，无需修复的发现；
未判断范围逐项裁定见[review.md](evidence/2026-10-11-subtitle-mp4-ttml/review.md)。
首轮四包1215/1215通过；格式化触发的一条curly-brace提示仅补大括号，在最终候选重新验证。
用隔离git-archive基线加所属14份代码/测试/二进制夹具逐字节对照，冻结SHA256与制品指纹，
独立Git index仅提交本项与自身总览/CHANGELOG段；另一边未提交脚本完整保留。
本项不关闭整个Task3/P02，执行账本继续保留。

最终命令为根目录四包 flutter test --no-pub --concurrency=1（接口/播放器/Apple/Android
四个test目录）以及播放器/接口lib/test的dart analyze --suppress-analytics。
结果 **1215/1215、0失败、exit0**（135/885/113/82；本项新增64），分析 **No issues found、exit0**。
基线ede8e48、所属候选、引用依赖、制品、完整日志和文档指纹见manifest，复审无遗留项。

## 2026-10-11 分片 MP4（fMP4）内嵌 WebVTT / TTML

按用户指定下一项，在既有 MP4 runtime 接入同一完整文件/稳定 HTTP(S) 资源的初始化信息与
moof/mdat。公开 discovery、Track ID 选择、WebVTT/TTML 样式/区域渲染和 managed 网络接口
不变，无新增依赖或 native 声明。具体语义与拒绝成本见 [fMP4 契约](../specs/2026-10-11-subtitle-fmp4.md)。

- trex → tfhd → trun 默认值覆盖；显式零值保持零。tfdt 32/64位、trun signed/unsigned
  composition offset、多个run/traf、64位box、显式/moof/首traf隐式基址和负data offset。
- 字幕sample必须位于mdat payload，不接受字幕字节重叠、decode时间倒退、重复序号或损坏结构。
  音视频payload跳过，不推测后续traf的隐式基址。结构/样本/cue/run/XML/读取预算跨片累计。
- WebVTT使用sample区间；TTML使用composition文档时间，经sample裁切与简单edit映射一次。
  分片的播放edit duration=0按后续媒体处理，仍保留7天上限；不改变非分片行为。
- 沿用强ETag/If-Match/总长/最终URI固定、单段206和managed retry/redirect/credentials/
  connect/read超时；无全量下载回退。后续分片取消/失败不发布部分目录。
- 单资源范围不包含独立init/media URL、HLS/DASH字幕清单、直播增长发现、fragmentedtx3g、
  hybrid字幕初始化sample、加密/辅助资源或高级WebVTT/TTML；对应成本是这些素材明确拒绝，
  不将本项外推为全部fMP4/设备或整个P02验收。

起点d0feaaf。真实文件入口先0通过/1失败（subtitleUnsupported），接入后包含既有MP4/STPP
回归106/106。扩展parser第一轮夹具括号/类型拼写导致加载失败，修正后60通过/2失败：
合法is_leading=3被错误视为reserved、truncated tfdt夹具造成后继box unsupported分类。
前者修正依赖flag字段校验；后者改为精确version/length冲突。补充全局预算/byte重叠后，
新增84/84通过（66parser、1实际文件、11真实HTTP、6公开会话/Flutter测试）。

真实HTTP验证自动/显式MP4嗅探、跳过5MB媒体区、If-Match、chunked206、重试与凭据剥离、
失败保留旧目录；会话测试验证实际TTML region矩形/粗体与WebVTT切换、off/offset/seek，以及
后续分片请求被换源/stop/dispose/外置目录操作取消后不能迟到发布。使用owned BMFF/XML
夹具与fake视频backend；无独立生产器正向互通、native构建、真机/HDR/DRM/PD-03验证。

另一会话提交abf1eab，仅5项P05文档/证据；隔离候选已刷新这些提交，未纳入其未提交
benchmark变更。四包初轮1299/1299（135接口/969播放器/113Apple/82Android）。首次分析
15项braces风格info，经自动及嵌套循环手动修正；没有静默丢弃初轮日志。独立复审、最终
冻结验证和commit证据在下方追加及 [manifest](evidence/2026-10-11-subtitle-fmp4/manifest.json)。

最终独立只读复审：新增Critical0/Important0/Minor0；没有阻塞修复或第二轮复审。十项
未判断范围及执行者裁定逐项记录于[review.md](evidence/2026-10-11-subtitle-fmp4/review.md)。
此前wvtt嵌套box全局计数Minor继续按已记录边界延期，未发现新增影响。

最终隔离副本基线abf1eab，七份代码/测试文件与候选逐字节一致；四包**1299/1299、0失败、
exit0**，新增84项，包计数135/969/113/82。播放器与接口lib/test静态分析**No issues found、
exit0**。十项既有native/构建制品独立重新计算SHA256均不变。最终源文件/引用依赖/原始日志/
报告指纹冻结到[manifest](evidence/2026-10-11-subtitle-fmp4/manifest.json)，用独立Git index
仅提交本项文件及自己的总览/CHANGELOG段；另一会话未提交benchmark不纳入。

## 2026-10-11 分片 MP4 tx3g（mov_text）

按“继续下一项”补齐上一切片已明确的fragmentedtx3g缺口。唯一生产行为扩展为移除分片
模式下tx3g格式拒绝，保留空初始化字幕表要求；已有trex/tfhd/tfdt/trun解复用与tx3g解码/
样式渲染组合，无API/native/网络reader改动。公开格式仍为归一化srt，编码是tx3g；契约与
后续范围见[tx3g延续契约](../specs/2026-10-11-subtitle-fmp4-tx3g.md)。未修改另一边长播放/弱网ABR。

基线47908dd，先记录真实文件入口0通过/1失败（subtitleUnsupported）。开放门禁后入口与
既有MP4/fMP4回归128/128；旧“拒绝fragmentedtx3g”测试改为拒绝未知codec。新增**43/43**
通过：24解析、2真实文件/独立封装、11HTTP、6公开会话/Flutter，静态分析No issues found。
验证继承duration/size、默认description样式切换、Unicode/UTF16/CRLF、整轨forced身份、
有符号composition offset与edit、空文本/终端零时长、非法样式及跨片4MiB预算。HTTP验证
managed Range/If-Match/重试/重定向凭据/失败目录保留；Flutter验证字体/字号/粗体/颜色、
切轨/off/seek/正负偏移和后续分片取消的迟到隔离。

hostFFmpeg8.0.1独立封装自有64×64黑视频+SRT，以empty_moov+frag_keyframe+
default_base_moof输出；TrackID2、mov_text、eng、微秒timebase，验证文字/粗体和精确区间。
首条文本实际容器区间为1–3.123s，虽然输入SRT结束2.5s；断言依据ffprobe容器样本，不将
muxer结果误报为parser时间缺陷。夹具/原始输入/探测结果与哈希收录于
[证据目录](evidence/2026-10-11-subtitle-fmp4-tx3g/manifest.json)。

仍不支持独立init/mediaURL、清单/直播增长、hybrid初始化样本、高级tx3g、加密/辅助资源。
视频后端使用fake，FFmpeg夹具是单生产器正向证据，未作native/真机/HDR/DRM/外接设备/
PD-03或完整P02验收。最终四包结果、独立复审和冻结提交核对如下方记录。

最终四包**1342/1342、0失败、exit0**（135接口/1012播放器/113Apple/82Android）；最终
lib/test分析**No issues found、exit0**。七份源/测试/二进制夹具与隔离候选逐字节一致，
十项native/构建制品SHA256重新核验不变。独立只读复审Critical0/Important0/Minor0新增，
无修复轮次；八项范围/验证裁定及已有wvttMinor延续见[review.md](evidence/2026-10-11-subtitle-fmp4-tx3g/review.md)。
正式仓库证据保留原始RED/GREEN、独立FFmpeg输入/ffprobe和最终日志，见[manifest](evidence/2026-10-11-subtitle-fmp4-tx3g/manifest.json)。
采用独立index只提交本项文件及自己的总览/CHANGELOG段，不含另一会话任务。

## 2026-10-12 混合 MP4 字幕（初始样本表 + 后续分片）

按“继续下一项”补齐hybrid MP4缺口；tx3g/wvtt/stpp可先读取普通stbl，再接续moof。
没有公开API/native/依赖/managed reader或renderer变更，仍使用Track ID与同一字幕owner；
[契约](../specs/2026-10-12-subtitle-hybrid-mp4.md)明确这是完整文件支持，不是MSE初始化声明。

删除非空初始化样本表的格式门禁；用每轨stts累计decode终点初始化后续tfdt下界，不受ctts、
edit或空/裁掉的cue影响。初始和后续共享packet/ordinal/TTML原始字节及预算；分片模式下
在发布前对所有字幕sample的byte extent统一检查重叠。保留所有原有codec/edit/寻址限制，
允许合法composition重叠和decode空隙；不同轨道的下界相互独立。

基线a9673dc。真实文件三codec入口先0通过/1失败（unsupported）；实现后旧分片回归与
入口91通过/1失败，仅独立FFmpeg样本断言误用了输入SRT终点2.5s，而ffprobe输出实际容器
终点3.123s。修正断言后parser/文件23/23；新增整套40/40（21parser、2file/producer、
11真实HTTP、6session/Flutter）。旧hybrid拒绝项替换成初始/后续decode重叠拒绝项，未删测试。

另在隔离副本临时移除decode下界，2项测试均从应拒绝变为错误接纳；移除全局extent计费，
2项字节重叠测试也均失败。两项mutation都恢复到原候选后才执行最终分析和四包验证，
原始失败日志保留。网络测试验证三codec前后内容、managed请求、版本/凭据/重试和目录
保留；Flutter验证初始文字切至后续区域文字、样式、选择/off/offset/seek与迟到取消。

hostFFmpeg8.0.1以frag_keyframe+default_base_moof封装自有黑视频/SRT，初始字幕stsz有
可见文字，后续moof有第二条；结构审计和ffprobe均保留于[证据目录](evidence/2026-10-12-subtitle-hybrid-mp4/manifest.json)。
字幕解码按容器0–3.123s、3.123–4.567s及粗体样式验证；不声称修正muxer输入时间。
三codec自有夹具、实际文件/HTTP和fake视频backend的Flutter验证不等价native/设备验收。

独立segment URL、字幕清单/直播、跨Period、高级效果、HDR/DRM/外接设备与PD-03及整个P02
继续开放。另一边长播放/弱网ABR未修改；最终复审/四包证据如下方追加。

最终四包**1382/1382、0失败、exit0**（135接口/1052播放器/113Apple/82Android），最终
lib/test分析**No issues found、exit0**。九份代码/测试/独立二进制夹具与隔离候选逐字节
一致；十项native/构建制品SHA256重新核验不变。一次独立只读复审Critical0/Important0/
Minor0新增，无修复轮次；逐项范围裁定与已有wvttMinor延续见[review.md](evidence/2026-10-12-subtitle-hybrid-mp4/review.md)。
源码/引用依赖/文档/原始失败与最终日志指纹见[manifest](evidence/2026-10-12-subtitle-hybrid-mp4/manifest.json)。
用独立Git index仅提交本项和自身总览/CHANGELOG段，不涉及长播放或弱网ABR。

## 2026-10-12 Matroska WebVTT 字幕

按“继续下一项”扩展同一 file/managed HTTP 字幕发现入口：标准 S_TEXT/WEBVTT 和
FFmpeg 实际生成的 D_WEBVTT/SUBTITLES/CAPTIONS 分别解析，以 TrackUID 选择并进入
现有 WebVTT renderer。S 映射验证 CodecPrivate 与 BlockAdditional ID1，D 映射读取
Block 中 identifier/settings 前缀；二者要求显式 BlockDuration。无公开API、原生、
managed reader 或 renderer 变更；[范围契约](../specs/2026-10-12-subtitle-matroska-webvtt.md)。

所有头和注释原始字节保留到 sourceBytes，参与扫描和共享目录4MiB预算。未知addition、
无效元数据/UTF8、cue注入和高级WebVTT均拒绝，目录失败不替换旧选择。保留既有文档/
结构/时长/字符/并发cue限额。该范围不包括WebM DocType、字幕清单、直播或跨Period。

基线ba64b1c。实现前入口集12通过/22失败（原有codec门禁），实现后81/81含旧Matroska
回归。新增55/55：38解析/真实文件/预算，11真实HTTP，6session/Flutter。HTTP覆盖
单段206/If-Match、鉴权、重试、跨源凭据剥离、版本错误、超时与目录保留；Flutter
覆盖同语言main/forced两映射切换、粗体/25%横向位置、正负offset、seek/off与迟到取消。

自有subtitle-only MKV由host FFmpeg8.0.1独立封装D_WEBVTT，按ffprobe0.503–1.707s验证；
S_TEXT映射使用自有EBML样本，无独立生产器互通声明。输入/命令/probe保存在
[证据目录](evidence/2026-10-12-subtitle-matroska-webvtt/manifest.json)。

在隔离副本暂时删除sourceBytes传递，两项“先内嵌/先外挂”累计超限测试均从应拒绝变为
错误接纳（0通过/2失败），证明注释不能绕过目录预算；恢复候选后进行最终验证。
完整P02、HDR/DRM/外接设备与PD-03仍开放，视频backend为fake，不等价实机播放验收。

最终隔离四包**1437/1437、0失败、exit0**（135接口/1107播放器/113Apple/82Android），
lib/test分析**No issues found、exit0**。七份源/测试/二进制夹具与测试副本逐字节一致；
十项native/构建制品SHA256重新核验不变。一次独立只读复审Critical0/Important0/新Minor0，
无修复轮次/重复复审；九项范围裁定与旧WVTT Minor延续见
[review.md](evidence/2026-10-12-subtitle-matroska-webvtt/review.md)。
证据、引用依赖和提交文件指纹冻结于manifest，独立Git index仅提交本项及自身总览/
CHANGELOG段；长播放与弱网ABR无改动。
