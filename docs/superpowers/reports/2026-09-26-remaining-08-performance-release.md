# P08 执行记录：测量工具

执行日期：2026-09-27。需求 REQ-14、REG-DIAG/LIFE；起点 `540931352a1e4dac38cd794eaf452577badf5dab`，分支 `codex/fel-integration`。开始时只有上一轮九份规划文件及架构入口修改，保留并纳入计划基线。

## 已实现及尚未完成

新增 `tool/playback_benchmark/summarize.py`、行为测试与 README；示例新增 `FirstFrameProbe`、4 个 probe 测试、4 个安全记录测试及真实本地 AVC/AAC MKV smoke。统计工具进入 `tool/check_foundation.sh` 的测试发现入口。

每次计时从公共 Load 前开始，首帧事件先于 Load 返回也能保留，按返回 session 匹配；旧会话、重复及关闭后的事件不能替换首次观察。使用同一个 Dart 单调时钟，不混用原生 epoch。JSONL 验证源/依赖/制品/样本哈希与设备条件，拒绝混组、缺失/重复试次、非有限/负数、秘密样式字段和额外 payload。超时/失败/跳过/取消保留在分母，缺数据不等于 0。

**P08-A 仍在进行中，P08-B 尚未冻结指标。** 本切片测的是公开首帧事件接收，不是硬件扫描/Flutter 最终可见呈现。Apple AVPlayer 路径在 `textureOutput.publish` 后发出事件，未提供 compositor 呈现 ACK；还需补足正式呈现边界与 JS/许可证阶段观察。没有把该事件耗时冒充完整需求中的显示耗时。seek、切台、同步、资源/热和长播基线尚未完成。

## 测试证据

- Python：实现前 10 项因工具不存在失败，实现后 10/10 通过；涵盖统计、无成功样本、严格身份/条件、试次完整性、CLI 安全错误和重复 JSON key。
- Dart：实现前 probe 测试因缺实现失败；首次示例完整测试 18/18 通过；复核修复后最终 22/22 通过（新增 probe 4 项、记录与脱敏 4 项）；最终 5 个 Dart 文件静态分析无问题。
- macOS 实际播放：1 个集成 suite，3/3 试次公开首帧与持续 position 推进通过；实际使用 owned `h264_aac.mkv`，不是 mock 播放器。
- `sh tool/check_foundation.sh --release-core` 通过：工具检查及各 Dart 包回归均通过；其示例部分为修复前 18 项，修复后单独重跑完整示例 22 项并通过，未重复无关包。
- 独立复核发现两项 Important、无 Critical/Minor；已在一次修复中补测试并通过：清理超时/异常不得丢观测，输入必须在打印前脱敏校验。最终源码另做 macOS 3/3 重测及 8 文件哈希核对。

初始两次工具调用的工作目录/沙箱问题已纠正：Flutter 缓存需提权、集成需在 example 运行。缺文件的初次命令不算播放失败样本。代码前的 RED 记录与有效运行日志分开保留。

## macOS instrumentation smoke

| 条件 | 记录 |
|---|---|
| 主机 | Apple M1 / MacBookPro17,1，16 GB，macOS 27.0 (26A428)，arm64 |
| 构建 | debug，仅测量链路检查，非 release 基线 |
| 样本 SHA-256 | `0998ccdd25d75b238a2a4bc9283f6c794e432b1983d13276716345d31cdb0288` |
| 运行源码指纹 | `9c849e9c0cb4c0d84d9ca0b16405133369cdf1ffda84879f55be1885332b3d75`（运行时源树，非最终文档指纹） |
| 依赖指纹 | `82086a5881ea237d64ee4b26b357e5172d5736c2cd2c3d35baf02cfead37a15d` |
| FFmpeg 制品指纹 | `4ac382638e2bdff6031baf6dced538f645906f12081576920aa0fe72052b50a1` |
| 次数 | 预先设为 3，3 次均保留 |
| 公开事件接收耗时 | 150313 / 31092 / 28780 µs |
| 统计 | median 31.092 ms；nearest-rank p95 150.313 ms，n=3，只描述本次 smoke |
| 缓存/热/电源 | OS cache uncontrolled / thermal unknown / power unknown，不具备正式基线条件 |

**限制：** 构建有既有 Xcode stale-file/SPM-CocoaPods 提示；运行器提示 `Failed to foreground app; open returned 1`。即使试次回调/position 均通过，也不能据此宣称窗口可见、实际音频正确或屏幕呈现验收通过。不得从这三个 debug 样本制定正式 SLO 或改善百分比。

最终试次标识为 `macos-smoke-20260927-3`，早期和中间版本另存 `initial-smoke/`、`review-fix-smoke/`，不与最终组混算。运行源码树指纹包含当时的宿主缓存；独立 `final-code-hashes.json` 对 8 个手写代码/门禁文件核对，全部与最终文件及实测时内容匹配；后续正式基线应排除生成缓存。

原始受控证据在本计划独立忽略目录 `.superpowers/sdd/2026-09-26-remaining-08-performance-release/`：`macos-smoke.jsonl`、`macos-smoke-summary.json`、`macos-smoke.log`、`context.json`、`source-identities.json`、`dart-defines.json` 与 RED/GREEN 日志。后续正式基线必须保留可取回证据；该工作目录是本次本机复现材料，不假称远程 CI 制品。

## 设备盘点和下一步

提权查询确认没有连接的 Android 设备，也没有正在运行的 iOS 模拟器；没有取得物理 iOS、API24 低内存/32-bit、Intel macOS 或最低系统的本次运行证据。未启动的可用模拟器清单尚未作为性能设备矩阵核实，不能据此宣称“没有可用设备”。

下一步补正式呈现观测与可控 profile/release 测量；在可用设备上确认图像/音频正确、缓存/热状态及重复次数后冻结对应目标。P01 SegmentBase/sidx 不受 DRM 资源或这些未测设备阻塞，仍按总览顺序推进；本切片未修改 DASH 播放支持范围。

## 实施决定

- 延续当前 checkout 和分支：已有持续实施授权且无外来代码改动；代价是依赖精确文件范围提交。
- P08 A/B/C/D 改为数字 Task 1/2/3/4 并保留字母：执行工具只识别数字任务；内容和依赖不变。
- 首帧仅命名为事件接收测量：避免跨 epoch 计算及虚构显示完成；代价是正式呈现指标与完整 A 仍未闭合。
- debug/未知热状态/非受控缓存只作为 smoke，未创建数字阈值：代价是不能马上声称性能改善，保持真实验收。

## 独立复核修复与保留边界

- 观测在清理前同步保存；清理设 5 秒 deadline，超时或异常不能保留“通过”的最终行。因为 Future.timeout 不保证原生清理停止，后续播放器尝试中止，并显式记录为 skipped。原始 playback timeout 仍保留 timeout，不被未知清理异常覆写。
- Dart 入口先验证完整字段白名单、哈希和安全标签，再输出元数据；不通过 expect 打印任意输入，所有配置解析错误使用固定安全信息。Python 再独立验证完整试次和分组。
- 复核未判断的可见呈现、阶段指标、正式基线、长播/资源/最低系统和 DRM/Dolby 仍明确未完成；其代价是完整 P08-A/B 保持进行中。
- 无暂缓 Minor 项。不会将本切片描述为性能优化完成、SegmentBase 已实现或整计划通过。


## 2026-09-30 AV1 预算前置核查

P03增加[实际VT会话探测](../../../tool/decoder_probe/README.md)：当前M1的AV1 Main8/Main10共12次会话创建均无decoder，对照AVC6次完整硬解输出。此结果不是性能测量，不产生CPU/RSS/热阈值或优化比例；软件预算继续unmeasured_not_admitted。需先补完整A的资源/热/呈现观察，再在固定设备和候选软件decoder上按B冻结基线。Host FFmpeg能独立解码只证明输入有效，不是生产软件路线或预算证据。P08-A/B仍未完成。


## 2026-09-30 进程资源测量子项

起点 `fb54583518b25eff0c64137e6dabf46353dae1c6`，沿用当前分支。新增测试专用 Objective-C 动态库、Dart FFI 采样、公开播放生命周期试验和 Python 包装/统计工具；未修改产品播放引擎、公开 API、沙箱权限或部署下限，也未接入商业 SDK。

CPU 读取 self-process `getrusage` 用户态与内核态累计微秒；RSS 与 physical footprint 分别读取 `proc_pid_rusage` 字段，不混成同一内存指标。时间来自 native monotonic raw clock；250 ms 为名义采样间隔，统计按实际观测时间加权，100% 表示一个 CPU 核。缺失点/跨阶段不连 CPU 差分，时钟回退与计数器重置明确拒绝。原生计数器测试以 32 MiB 实际触页和 CPU 工作验证响应，只证明计数器可用。

系统热状态不代表温度，电源未知时保留 unknown；温度、GPU、媒体内存账本仍为 null。语义依据为 Apple [thermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property)、[XNU 资源计数器](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) 和 [getrusage 计时精度](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md)。

### 最终可复查证据

- [完整原始试次、阶段摘要和身份映射](../../../tool/playback_benchmark/macos-resource-observations.json)，运行 `macos-resource-20260930T132259Z`，包装器和 Flutter 退出 0。
- 主机 Apple M1 / MacBookPro17,1 / macOS 27.0 (26A428)，debug，local-file，OS cache uncontrolled；94 点均 battery/nominal，无资源缺失。与此前 AV1 会话可行性结果分开，不合并成软件预算。
- 媒体为原创四秒 `format_matrix/mkv-avc-aac.mkv`，SHA-256 `0812b7fcb4c587e51621b8e1f08ab494c062a2c345e47ad0ba9a1bfce80230b3`。
- 源码/构建配置映射 SHA-256 `2b09cbb9fd64ce9277d3b4620b102defd7e9c6233cde2554b7b7436f139b50e3`；包含未提交源码和测试，以及 Podfile.lock、project/xcconfig/podspec、manifest/entitlements。运行后逐文件与依赖映射核对无差异；不声称覆盖所有外部 SDK/工具或忽略的生成缓存。
- 固定三次、同一进程，均为 managedFallback/hardware；分别 32/31/31 点，五个阶段 idle/opening/playing/disposing/disposed 均有观测。采样库只加载一次，避免重复映射本身干扰释放观察。

| 试次 | playing 实际采样窗口 | 单核归一 CPU 加权均值 | playing RSS 峰值 | playing physical footprint 峰值 |
|---|---:|---:|---:|---:|
| 1 | 1.998 s | 13.04% | 265.78 MiB | 154.59 MiB |
| 2 | 1.929 s | 15.42% | 268.77 MiB | 156.45 MiB |
| 3 | 1.947 s | 14.02% | 265.64 MiB | 156.20 MiB |

这些数字仅描述本次整个 debug 进程，包含 Flutter、测试和采样开销，不是 decoder 专属消耗。idle 计划等待 2 s，但各阶段采样窗口由实际首尾点确定；尤其 opening 的后两次只有约 1–2 ms 的采样覆盖，不用这个局部窗口冒充完整打开阶段成本。playing 从公开首帧回调起至媒体位置达到 2 s；disposed 在公开释放及移除视图完成后再观察 2 s。短时峰值、首末值不能证明稳定态或无泄漏，也不要求 RSS 立即归零。

### 验证与复核

Python 25/25（含严格统计、缺失/失败/跳过完整性、真实 native 计数器和拥有进程组的超时清理）；Dart 8/8（含创建超时、迟到实例单次释放及释放异常吸收）；三文件 analyze 无问题；最终 macOS 1 个集成 suite 内预定 3/3 试次全部通过。新增 Python 测试由既有 foundation 入口发现，Dart 单测由 example test 目录发现；需要测试动态库配置的真实资源试验使用 README 独立入口，不加入无配置集成清单。

一次独立复核发现 Important：创建播放器没有局部超时，挂起会丢掉内存中的观测；Minor：构建配置指纹覆盖不足。两项均已修复。创建有 10 s deadline，超时保留 timeout 行并跳过后续，迟到实例继续由 helper 接管并限时释放；Future.timeout 不取消 native 操作，不能证明原生已立刻停止。超时回归先观察缺实现 RED，再实现 GREEN。局部清理最多 5 s，suite 外层 4 min、包装器 build/run 10 min；外层失败保留日志和失败状态，缺试次不能当通过。

初期从外部临时目录 dlopen 被 app sandbox 拒绝：首轮 1 failed/2 skipped、空采样，未冒充资源证据。最终使用 Dart define 携带测试库字节，在 app 自己的临时目录写入并加载，无权限放宽。中间成功版本与最终版本分开保存，不回写旧指纹。忽略的本地证据目录 `.superpowers/sdd/2026-09-26-remaining-08-performance-release/` 下 `resource-development/`、`resource-pre-review/`、`resource-final/` 保存 RED/GREEN、诊断和实跑日志；已提交 JSON 保留最终 raw observations 和日志 SHA-256，不假称这些本机日志是远程 CI 制品。

最终运行仍有 `Failed to foreground app; open returned 1`，因此几何/音轨/时间线检查只验证播放状态，不能宣称窗口可见、音质或物理呈现正确。初始测试命令的目录错误、Flutter 缓存权限、generic 推断静态检查错误均修正，不能计为播放器通过或失败试次。

**本次仅完成资源测量工具子项；P08 Task 1/A、Task 2/B 仍未完成。** 后续先补可见呈现/音画正确性、受控 profile/release 测量协议及正式资源基线，再按候选 decoder 冻结软件预算。seek/切台/同步/JS/许可证阶段、GPU/媒体账本、长期增长、其他平台和最低系统仍待完成；不启用 AV1 软件路线，不输出优化百分比。


## 2026-09-30 暂停显示层像素回读子项

起点 `c7bc8a2`。为 example macOS Debug 宿主新增只读 method channel，遍历自己窗口中的 AVSampleBufferDisplayLayer，要求唯一输出层，通过公开 [displayedPixelBuffer()](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/displayedpixelbuffer()) 回读。当前 SDK 明确该接口在非零播放速率或受保护/不可用图像时可返回 nil，故试验主动暂停后读取；不获取屏幕权限、不读取其他应用、不改变生产包接口/内核/最低部署版本。探测自身要求 macOS 14.4+；profile/release 不编译该通道。

三个预定试次均使用同一原创 AVC/AAC BT.709 文件，经公共 Player/Session 播放，在媒体位置达到 0.25/1.25/2.25/3.25 s 后暂停。Core Image 按输出元数据转换为 sRGB RGBA8，取四分之一/中心/四分之三位置组成的九个内点；每点每通道与红、绿、蓝、白顺序标记误差不得超过 24/255。纯黑、不完整顺序、跳色、倒序和任一点不匹配不能通过。创建前/释放移除视图后都检查 noLayer；每次原始观测先于清理输出，失败/超时保留，随后试次显式 skipped。

### 最终结果与身份

运行 `display-20260930T133656Z`，Apple M1 / MacBookPro17,1 / macOS 27.0 (26A428)，Flutter debug，local file、OS cache uncontrolled，电源/热状态本次未测。完整[源身份与原始回读](../../../tool/playback_benchmark/macos-display-readback-observations.json)已提交；源映射 `dac418988510ffd09c4255da9b67480bddc61e98ea308b14a50a1b6e044b644f`，媒体 `eff602e743256a41a50cb5ea25d94446d2518eb7eedd93673d9ba9d1019c9995`，运行后源码/构建配置/依赖/媒体逐一核对一致。命令见工具 README。

| 标记 | 目标 RGB | 最终三次回读 RGB（各九点相同） |
|---|---|---|
| 红 | 255,0,0 | 251,0,0 |
| 绿 | 0,255,0 | 0,253,0 |
| 蓝 | 0,0,255 | 0,0,252 |
| 白 | 255,255,255 | 251,253,253 |

3/3 试次通过，共 12 个标记帧、108 个 RGB 点；另有 6 个 noLayer/noImage 过渡观测完整保留，没有算作成功像素。三次均 managedFallback/hardware，释放后 layerCount=0。新增 Dart 标记测试 4/4、复用资源/创建生命周期测试 8/8，通过合计 12；三个 Dart 文件静态检查无问题；macOS 实际构建及集成退出 0。没有重跑无关完整媒体/原生 suite；新增 Dart 测试由 example test 目录发现，集成是需要显式 runId 的 README 独立入口。

### 失败、方法修正与复审

- Dart RED 为 helper 尚未实现；原生通道实现前的真实运行在 setup 失败，1 failed/2 skipped，不能当输出证据。
- 第一轮用旧 `format_matrix/mkv-avc-aac.mkv`：实际已回读图像，但红色为 248,36,0，超出原先固定 24 容差，1 failed/2 skipped。ffprobe 确认旧素材缺少矩阵/原色/传递函数完整标注。没有放宽容差，也没有修复或宣称修复未标注内容的生产色彩解释。
- 新 `benchmark_sdr.mkv` 用 FFmpeg 明确把 lavfi BT.601 色值转换为 BT.709，并通过 setparams 与编码元数据同时标注 limited range、矩阵、原色、传递函数。生成器首次检查发现仅矩阵生效，元数据断言失败，保留中间素材及结果；补齐后独立 ffprobe/FFmpeg 验证通过，RGB 为 250,0,0 / 1,254,0 / 0,0,253 / 251,253,253。最终集成使用此已验证固定哈希素材，旧/中间/最终结果分组，不能据此输出性能改善百分比。
- 一次独立复审无 Critical/Important，两项 Minor 记账暂缓：清理在单个 try 中，先前步骤失败会跳过后续移除视图/临时文件删除；创建超时后 `player=null` 时 `cleaned=true` 不证明迟到原生创建已释放。两种路径始终为 failed/timeout 并跳过后续试次，不产生通过；仅成功试次可确认完整清理。后续扩展失败路径时应分开独立清理并记录迟到释放是否已确认。
- 本地原始证据在忽略目录 `.superpowers/sdd/2026-09-26-remaining-08-performance-release/display-development/` 与 `display-final/`；已提交结果保留所有最终回读和完整日志 SHA-256，非远程 CI 制品。

### 能力边界与下一项

`firstReadbackDelayUs` 从 Load 前同一 Dart 单调时钟计到首次匹配回读返回，包含主动播放等待、暂停、50 ms 轮询、通道和像素转换开销，**不是首帧延迟**，不写入 firstPresentedUs、不汇入延迟统计或阈值。回读观察到的是系统显示层提供的暂停图像，不是 compositor ACK、最终屏幕/显示器色度或物理扫描；均匀色块的九点也不能证明全图几何/旋转/细节正确。

最终运行仍有 `Failed to foreground app; open returned 1`。因此不宣称实际窗口可见、物理音频/同步、HDR/杜比或跨设备画质通过。Debug 宿主探测和 Core Image 本身有开销，不能与未带探测的性能结果直接比较。正式无暂停呈现时序、受控 profile/release 协议、音频/同步与资源长播基线仍需补齐；完整 P08 Task1/2 和 AV1 软件预算仍未完成。后续优先处理呈现时序可观测边界及上述失败清理，再冻结可用设备的性能采样协议。


## 2026-09-30 显示回读失败清理修复

起点 `d0a6a7a`。上一子项记账的两项 Minor 已修复：独立执行 dispose、移除视图、检查残留层及删除临时文件，每一步有独立 5 s 时限；任一步异常/超时不跳过后续步骤，最终 cleaned=false。创建没有确认交接时也保持 cleaned=false，迟到实例继续由既有创建 helper 接管释放；迟到完成不追认之前的试次，也不启动后续播放。清理未确认表示未知，不能解释为永久泄漏已被证明。原先 timeout 保持 timeout，其余清理失败记 failed。

新增 7 项行为回归涵盖四个清理步骤各自抛错、释放挂起及迟到异常、创建超时/迟到释放，以及正常交接的顺序执行。先观察缺实现 RED，再实现；最终新增 7 项和相关 12 项合计 **19/19** 通过，三文件静态检查无问题。真实播放器未注入原生故障；故障路径由可控 Future/清理回调验证，实际 macOS 运行验证正常路径，二者不混称真机故障注入。

最终 `display-cleanup-20260930T134619Z` 真实集成 **3/3** 通过，均 managedFallback/hardware，四段九点标记通过、前后无残留层、cleaned=true，Flutter 退出 0。[独立修复后证据](../../../tool/playback_benchmark/macos-display-cleanup-observations.json)保留原始行和源码映射 `c3d5f2a19cd55a520c570ca8be6d162736f5432ead58cf257d5550d0d6981b50`，源码/依赖/媒体哈希核对一致；旧运行文件不改写。原始日志在本计划忽略目录 `display-cleanup/`。

只修复测试工具生命周期，未改产品引擎、原生回读、素材、色彩容差或指标定义。仍有前台激活失败提示，不声明物理显示或正式性能基线通过。旧未标注素材的颜色解释差异、无暂停呈现时序及受控性能基线继续待完成；完整 P08 Task1/2 不勾选。


## 2026-09-30 色彩参考条件核查与修正

起点 `ec9f84b`。本次定位旧未标注 AVC 素材红色回读 248,36,0 的差异，修正测试工具的参考资格判断；没有改生产解码、渲染或未标注内容的默认色彩策略，也没有放宽 24/255 容差。

原始回读缓冲区的红块 YUV 为 81/90/240，矩阵为 BT.601、传递函数为 BT.709，原色附件为 `ColorPrimaries#2`。固定这些 YUV 样本的独立 Core Image 对照显示，更换原色解释会改变转成 sRGB 后的结果；因此现有证据不能把差异归因于损坏的解码样本或错误的 YUV 矩阵。新增 `benchmark_601.mkv` 仅补 SPS/容器色彩标记：BT.601 矩阵、BT.709 原色及传递函数。FFmpeg 比对全部 96 帧视频及 189 帧音频的解码哈希，与旧素材完全一致；旧素材本身保持不变。这是测试参考对照，不是针对未知来源媒体的生产修复。

首次采用“原色附件必须为 BT.709”的资格规则时，两个已标注正例都被误判为 `reference-unqualified`，各 1 条不具备资格、2 条 skipped，Flutter 退出 1；保留该失败矩阵。进一步实测发现三个素材的回读原色附件均为 `ColorPrimaries#2`，但两个正例的 `CIImage.colorSpace` 为 `kCGColorSpaceCoreMedia709`，旧未标注负例为空名称的色彩空间。空名称不等于没有色彩空间，不能直接按 sRGB 解释。

最终 schema 2 保留矩阵、原色、传递函数和实际用于转换的 Core Image RGB 色彩空间四个白名单标签。只有 BT.601/709 矩阵、BT.709 传递函数、Core Media 709 RGB 空间及 BT.709/规范化未指定原色组合可以使用本测试的纯 RGB 参考；其他或缺失的空间、明确冲突的原色均记录 `reference-unqualified`，保留像素并跳过后续试次。色彩空间来自原样构建且随后用于转换的同一个 CIImage，不覆盖缓冲区附件，也不强设输入色彩空间。该规则只服务于这组自有 SDR 色块，不定义播放器对其他色彩空间的支持范围。

新增行为测试先观察 RED，修复后 **23/23** 相关 Dart 测试通过，三个文件静态分析无问题。覆盖规范化原色附件、BT.601 对照、缺失/未知/冲突空间和原色即使像素碰巧匹配也不能通过；保留原有四段顺序、九点像素、清理和资源测试。

最终运行 `color-reference-20260930T140521Z`：BT.709 正例 **3/3**、BT.601 元数据对照 **3/3**，合计 24 段标记图像、216 个 RGB 采样点通过；旧未标注负例为 **1 reference-unqualified / 2 skipped**。三组 Flutter 均退出 0，其中负例退出 0 只说明“参考不足”分类符合预期，不能计为原素材画质通过。七次实际创建均确认清理和释放后无层，正例均 managedFallback/hardware。独立复审未发现新增代码问题。

[最终及首次误判的完整证据](../../../tool/playback_benchmark/macos-color-reference-observations.json)分别保留源身份、命令、试次/回读、媒体/依赖和日志哈希，最终 sourceHash `7f18bd8d9afb7865ba24d37294474f726bb4f90a361062ac196939185a15376c` 已逐文件核对一致；原始诊断和日志归档在本计划忽略目录 `color-reference/`。完整 P08 Task1/2 仍未完成：本次关闭的是颜色参考判定误报，未标注素材的实际色彩准确性仍未知。仍有前台激活失败提示，不宣称屏幕实际可见、物理色度、音频/同步或正式性能基线通过。下一项继续无暂停呈现观测边界与受控 profile/release 测量协议。


## 2026-09-30 呈现边界审计与 profile 基线准入

起点 `66a0c49`，工作区干净。继续 P08 Task 1/2，新增[测量协议 v1](../../../tool/playback_benchmark/measurement-protocol.md)，本项不改生产播放器、不设置性能目标。

核查 Apple 生产路径与本机 SDK：AVPlayer 先发布 texture 再发公开 FirstFrame；managed 路径发布帧/提交 sample buffer 也不是 compositor 呈现确认。`displayedPixelBuffer()` 要求暂停，`AVVideoPerformanceMetrics.totalNumberOfFrames` 包括本应显示但被丢弃的帧，不能拿累计计数替代首次真实呈现时间。当前可用手段尚未建立无暂停、关联 Session 的首次呈现边界；这不是证明其他观测方案不存在。

发现 Python 汇总入口存在准入漏洞：虽只允许 `load-to-public-first-frame-event`，却会接受 physical + profile/release + 已知电源/热状态 + warm cache 下的 `purpose=baseline`。这些条件无法补足呈现证据。现已对该事件 schema 明确拒绝 baseline，保留所有 debug/profile/release smoke；Dart 入口原本已限制 smoke，无需修改。新增/调整测试先复现 3 个失败（profile/release 正式基线误收及 CLI 错误输出成功），最终 **27/27 Python** 通过，验证 profile/release smoke 可用且不同构建模式不能混算。

profile 实跑预先冻结三次、无预热剔除、已有本地 AVC/AAC 素材及哈希、未知电源/热状态、OS 缓存不受控和未验证物理输出。首次 `flutter test --profile` 因不支持该参数退出 64，未启动播放；改用既有 `integrationDriver()` 后，双架构构建在 `lipo -verify_arch arm64 x86_64` 处退出 1。独立验证同一引擎文件的 arm64/x86_64 单架构各退出 0，双架构校验两个顺序都报错。之后限定本机 `FLUTTER_XCODE_ARCHS=arm64`，该环境变量由 Flutter 官方工具代码传递为 Xcode build setting；不改项目默认架构或外部 SDK。每次运行使用新身份并保留前次失败；本次结果不覆盖 Intel/universal 制品验收。

最终 `macos-profile-20260930T141527Z` profile/arm64 实跑 **3/3** 通过，Flutter drive 退出 0；实际宿主、App AOT 与 Flutter 引擎的制品均为 arm64，另存 SHA-256。源码、依赖、原生制品、媒体与协议指纹核对一致。[完整证据](../../../tool/playback_benchmark/macos-profile-smoke-observations.json)保留三条原始试次及前两次未启动播放的失败运行，原始日志在本计划忽略目录 `profile-admission/`。

公开事件到达间隔为 138396、33468、32577 μs；n=3、p50=33468、nearest-rank p95=138396 μs，仅为工具 smoke 的事件统计，不能称首帧呈现延迟、稳定性能目标或相对 Debug 的优化效果。实际 kProfileMode 与上下文一致；release 未实跑。前台激活仍失败，且日志有 integration_test native plugin 未检测到提示；本次通过由 VMService integrationDriver 成功返回和完整三条最终行共同确认，不把该提示忽略为原生 XCTest 集成已通过。编译 warning 原样留在日志。

本项完成基线准入修复、观测边界审计及 profile 实跑入口验证，**完整 P08 Task1/2 仍未完成**。无暂停真实呈现、受控缓存/电源/热状态与音画资格仍是正式基线缺口；不冻结阈值、不声明物理输出或 Intel/universal/release 已验收。


## 2026-09-30 无暂停系统渲染统计

起点 `91d20ac`。本项推进持续播放质量的观测工具，不再扩展公开首帧事件 smoke。示例宿主在已有自有窗口/显示层探测通道增加只读 `performance` 方法，通过 macOS 14.4+ 系统 API 获取累计总帧、丢帧、损坏帧和累计帧延迟；不暂停、不改媒体时钟、不拦截解码/输出。原生回调有 2 s 截止、只回复一次，迟到结果忽略；Dart 通道 3 s 截止。只有示例 Debug 或显式 `YL_VIDEO_PERFORMANCE_PROBE` profile 构建启用，未改生产包 API、默认构建开关或部署下限。

独立入口 `video_performance_test.dart` 预定三次，每次新播放器加载既有 BT.709 自有素材，公开首帧后约每 250 ms 采样，到媒体位置至少 3 s，窗口内没有 pause/seek/换会话。10 s 轮询和 80 条上限；缺少统计用 null 留样。只计算同一计数序列的首末差值，要求至少两次有效观察且总计数增长；负值、非有限值、时钟倒退或累计计数重置不能通过。schema/时钟不合法的载荷不直接写日志，以免泄漏任意字段或不可序列化数据，失败试次仍完整保留；有效的 reset/unavailable 样本在拒绝前留存。采样后继续使用已有四步独立清理；失败/未确认清理阻止下一次播放。

6 项新增行为测试覆盖缺失值、计数增长、零/不变计数、各累计值重置、时钟倒退、非法值、不可用、不可变样本及数量上限，先观察缺实现 RED，再通过合计 **21/21** 相关 Dart 测试；三文件静态分析无问题。首轮 profile 编译发现 AVFoundation 原先依赖另一个 Debug 块的 import，补成观测块自身 import；保留失败运行 exit1/0试次，最终用新身份重新编译。原生 deadline 的故障分支未做真实系统回调挂起注入，Dart 覆盖不可用输入和既有创建/清理故障分支，不混称原生故障注入通过。

最终 `video-counters-20260930T142752Z` profile/arm64 连续播放 **3/3**，均 managedFallback/hardware，合计 39 条有效 schema 采样（33 条系统统计、6 条初始 noLayer），三个窗口各增加 64 个系统总帧计数，丢帧/损坏帧增量均 0；每次释放后 layerCount=0、cleaned=true。观察窗口分别为 2659601、2651892、2671993 μs，是首末回调被 Dart 接收的间隔。系统累计帧延迟增量分别为 32.42215945、31.74829152、32.42212452 s；这是跨帧累计值，不能写成一次播放卡顿了 32 s，也不除以帧数宣称单帧实际延迟或 AV 同步误差，尤其本路线使用 DisplayImmediately。原样保留这些较大值，尚未赋予产品性能阈值含义。

共用通道的旧 Debug 暂停像素回读另跑 **3/3** 通过，四段九点检查和清理正常。两套数据分别保留，不能把 Debug 像素正确性当成 profile/物理画面已验收。[完整运行证据](../../../tool/playback_benchmark/macos-video-performance-observations.json)含最终原始样本、编译失败、旧行为回归及日志哈希；最终 sourceHash `4d7742e2abdb76c09ad1be79960a16667e4cfb1e1352d1b0c9425e777cc35080` 与源码/依赖/原生制品/媒体逐项一致，profile 宿主与 AOT 制品均 arm64。前台激活失败及 integration_test native plugin 提示继续留存，不冒充原生 XCTest 或屏幕输出验收。

本子项完成无暂停系统渲染统计工具，**不产生首帧呈现时间、正式基线、优化百分比或全量无丢帧承诺**。`firstPresentedUs=null`、performanceBaseline=false、physicalOutputVerified=false。完整 P08 Task1/2、长播资源/同步/物理输出和跨设备门槛仍开放。


## 2026-09-30 profile 重复创建/释放资源观察

起点 `526437f`。本项补充资源生命周期的跨轮观察，复用已有进程内 CPU/RSS/physical footprint 采样，未修改生产播放/解码路线。`run_resources.py --profile-cycles` 预先固定 10 轮 profile、每轮新播放器、250 ms 采样：空闲 2 s、播放至媒体位置 2 s、释放/移除视图/删除本轮媒体，然后继续采样 2 s。没有剔除首轮预热；每轮的阶段和失败/跳过完整保留。默认命令仍是原来的三轮 Debug smoke；本次新增模式的短循环不能替代长播或压力验收。

资源入口原来的单段失败清理已改为复用验证过的 `DisplayTrialCleanup`：创建未确认交接时不报告已清理，迟到实例仍由所有权 helper 释放；dispose、视图移除、临时文件删除各自有 5 s 截止，互不跳过。只在三步都确认成功后进入 disposed 采样阶段。已知样本在开始清理及异常清理前输出，不等待可能挂起的原生释放。未确认清理/采样错误/失败即跳过余下轮次。原生实际释放故障未注入，故障语义沿用已有可控 Future 的创建与清理行为测试。

新增释放后比较保留每一轮末端，包括失败/缺失。仅当完整轮次验证通过、至少两轮均成功、每轮 disposed 至少两条样本且覆盖 1 s、跨轮时钟不重叠、所有样本的电源/系统热状态已知且一致时，计算首末端点 RSS/footprint 字节差；身份畸形、轮次不完整或跨轮时钟重叠会被拒绝，runner 保留原始试次并记分类失败，不生成端点摘要；对结构合法完整的运行，失败/跳过、disposed 缺失/窗口过短或环境未知/变化才生成差值及比较窗口为 null 的端点摘要。最后一条不可用时不会回退使用此前正常读数。两个内存账本单列，不把缓存、分配器保留、observer 或 Flutter 开销归因到 decoder；增长不是已证明泄漏，下降也不是无泄漏证据，`leakVerdict=null`。

6 项新增 Python 行为测试先因缺实现 RED，再通过合计 **33/33**；覆盖实际端点、末读数缺失、失败/跳过/缺 disposed/单样本、环境变化/未知、跨轮重叠以及乱序身份。相关资源/独立清理 Dart **15/15**，两文件静态分析无问题。没有为纯命令参数添加镜像实现的单测，最终实跑验证 profile/轮数/命令与行身份一致。

最终 `macos-resource-20260930T144403Z`：profile/arm64 **10/10**，均 managedFallback/hardware，Flutter drive 退出 0。共 **311 条样本、0 缺失**，全部 battery/nominal；每轮释放后都有 10 个采样点，覆盖约 2 s。第 1 至第 10 轮释放后端点跨度 **57.738477 s**：RSS 从 **142262272** 到 **153731072 B**，增加 **11468800 B（10.9375 MiB）**；physical footprint 从 **55133216** 到 **69796896 B**，增加 **14663680 B（13.984375 MiB）**。保留所有中间轮次：第 5 轮有明显阶跃，末端也非完全稳定。没有删掉首轮、改变等待时间或重跑挑选更小增长。

这是一条需要继续归因的资源增长观察，不能直接宣布泄漏，也不能因播放/释放 ACK 成功就宣称资源完全回收。采样包含 Flutter、原生缓存/分配器、测量日志和观察器开销；本项没有分离这些来源，也没有冻结增长阈值。[完整证据](../../../tool/playback_benchmark/macos-resource-cycle-observations.json)保存每轮各阶段、末端和命令；最终 sourceHash `bbcfedf5ae8400b5091955e22a17918fdc01d3034748ac8de86f51aad8349903` 及源码/依赖/原生二进制/媒体/采样器哈希逐项核对一致。profile 宿主及 AOT 制品均为 arm64。原始日志保存在本计划忽略目录 `profile-resource-cycles/`。

前台激活失败和 native integration_test plugin 提示继续保留；十条最终行、VMService driver 成功返回证明本次循环执行，不替代物理音画、显示层消失、长播、Intel/最低系统或故障注入验收。**完整 P08 Task1/2 和 AV1 软件预算仍开放。下一项优先定位已观察到的释放后 footprint 增长来源**，采用同协议的可比对照/分配或资源所有权证据，定位前不做推测性缓存改写。

## 2026-09-30 释放后增长归因：无播放器对照

起点 `9bede85`。按 P08 先归因再优化，新增 `run_resources.py --profile-control`：与十轮 profile 播放保留相同媒体复制、空白 MaterialApp 挂载、250 ms 进程采样、日志、独立清理及前后各 2 s 等待，但不创建或加载播放器；`playing` 只是阶段名称，控制组等待墙钟 2 s，播放组仍等待媒体位置达到 2 s。新 schema2 明确区分 `harness-only` / `playback`，摘要保留标签，拒绝混合工作负载或 schema；schema1 继续解释为历史播放数据。对照成功不计为播放成功。原生插件仍会注册、库仍加载，不是剥离所有播放器代码的 Flutter 应用。

先对未改动的十轮播放做外部只读 VM 观察：`macos-resource-20260930T145352Z` 10/10，通过的 footprint 首末增加 **13402112 B**，第 5 轮阶跃再次出现。第 1–9 轮后 `getMemoryUsage` 可用，heapUsage 从 **8951104** 到 **7746320 B**，中间有涨落、没有持续上升；第 10 轮不可用。`getAllocationProfile` 请求被拒绝（-32602），不能据空类列表认定零存活对象。RPC 在日志行输出后发起，可能已进入下一轮，不能和端点当作同步读数；未强制 GC，Dart heap/externalUsage 与进程 footprint 账本不同，不能相减推算原生占用。此观察只缩小方向，未证明对象回收或泄漏。

随后按预先记录的协议，独立新进程先对照、后播放。首对运行 `145842Z` / `150011Z` 各 10 轮通过，也观察到无播放器时第 5 轮阶跃；自审发现 runner 将对照的墙钟等待误写为 `playingUntilMediaSeconds`，保留全部初采证据，修正为互斥的 `playingWallSeconds` / `playingUntilMediaSeconds` 后重新采集以下最终两组，未改变运行时测试协议或剔除高值。

| 最终组 | runId（macos-resource- 前缀） | 成功/计划 | 样本/缺失 | RSS 首末差 | footprint 首末差 | 端点跨度 |
|---|---|---:|---:|---:|---:|---:|
| 无播放器对照 | 20260930T150209Z | 10/10 | 300/0 | +3178496 B（3.03125 MiB） | +6520832 B（6.21875 MiB） | 54.452859 s |
| 实际播放 | 20260930T150336Z | 10/10 | 310/0 | +11616256 B（11.078125 MiB） | +14909440 B（14.21875 MiB） | 57.507022 s |

两组均为 MacBookPro17,1 / Apple M1 / macOS27.0(26A428)、arm64/profile、battery/nominal；播放组均 managedFallback/hardware，对照 engine/decoder=unknown。对照第 4→5 轮 footprint **50807816→60867592 B（+9.59375 MiB）**，播放组 **56902736→67454032 B（+10.0625 MiB）**；对照后来有明显回落。**该阶跃在不创建播放器时也可发生，因此不能仅凭先前阶跃判定播放器泄漏。** 但总增长来源、两组差异及具体保留对象仍未确定；不同阶段时长、profile/测试运行时、系统缓存、分配器与观察开销都未完全分离，不把差值当作播放器所有字节，也不宣布无泄漏。 进一步检查相邻采样，两组在首个 idle 采样后约 **27.205 / 28.205 s**、第 5 轮 playing 阶段均出现 **+8241152 B** 的单步增量；这是后续定位运行时/分配事件的时间线索，不是特定组件的所有权证据。

最终两组 sourceHash 均为 `da4468d6ed3e1390ff84338afc412872b290565abccd04c480becdcd7ec326e4`，源码、依赖、生产原生制品、媒体和设备身份逐项核对一致。采样 dylib 每次构建的 install name 含输出目录，完整二进制哈希不同；独立检查两组全部有文件内容的 Mach-O section 字节哈希及各 section 大小一致，原始哈希也保留，未声称 dylib 整体相同。验证脚本与 VM 探针原文/哈希随[完整五次运行证据](../../../tool/playback_benchmark/macos-resource-attribution-observations.json)保存；原始日志在本计划忽略目录 `resource-attribution/`。前台激活失败和 native integration_test plugin 提示仍保留，driver 退出 0 和最终行只证明测试执行，不替代物理画面/声音验收。

新增 4 项 schema/工作负载行为测试先 RED（缺新 schema/标签）后 **37/37 Python**；已有采样/独立清理 **15/15 Dart**，集成文件静态分析无问题。没有改生产释放路径：只读检查确认 registry 注销、coordinator dispose、managed session 取消输入/释放解码器与帧队列均有调用；公共 controller 会吞掉 backend dispose 异常，因此返回 ACK 仍不是完整原生回收证据。

本项交付可重复的空载对照和归因边界，**未完成泄漏归因、正式性能基线或完整 P08 Task1/2**。下一步在独立诊断协议中采集进程内存类别与原生对象生命周期/分配证据，区分测试运行时、分配器缓存及未释放媒体对象；未定位所有权前不修改生产缓存或释放策略。长播、多播放器、最低系统/其他设备与 AV1 软件预算仍开放。

## 2026-10-07 内存类别与大块分配诊断

起点 `aef6181`。本项继续归因，新增 `run_memory_categories.py`，复用既有 profile 十轮对照/播放入口，在接收到第 2、5、8 轮最终日志后验证 runId/schema/工作负载/PID，再要求 `ps` 返回本仓库 Profile 示例的精确可执行文件路径，才对该 PID 调用 `vmmap -summary`，每次截止 10 s。未扫描或采集其他应用。保留所有计划探针、未观察/失败状态、原文、哈希、主机起止时间；采集发生在日志接收后，可能已进入下一轮，不能称作同步的释放后端点。vmmap 可能暂停或扰动进程。

解析器只接收实际观测的 report version 7 与准确列序，拒绝错误 PID/版本/列序、重复类别、畸形或截断表；保留系统舍入单位和类别原名，缺类别不补零。virtual/resident/dirty/swapped 与 physical footprint 分开，不能求和或相减推算对象占用。新增 6 项行为测试先因缺模块 RED，随后加两项运行失败/已有证据保护回归，标准发现命令 `python3 -B -m unittest discover -s tool/playback_benchmark -p 'test_*.py'` **45/45 通过**。没有 Dart/Swift/生产代码改动，不重复无关媒体回归。

探索空载运行先确认系统工具可用，三次摘要均成功；随后按冻结协议先空载、后播放，最终证据如下。两组均 MacBookPro17,1 / M1 / macOS27.0(26A428)、arm64/profile、**ac/nominal**。与 9 月 30 日 battery 样本及无 vmmap 观察器的运行条件不同，不能用于优化前后比较。

| 最终组 | runId（macos-resource- 前缀） | 试验/计划 | 资源采样/不可用 | vmmap 成功/计划 | 第 2 / 5 / 8 轮后 physical footprint（系统舍入值） |
|---|---|---:|---:|---:|---|
| 无播放器 | 20261007T082733Z | 10/10 | 294/0 | 3/3 | 47.8M / 57.4M / 59.9M |
| 实际播放 | 20261007T082902Z | 10/10 | 304/0 | 3/3 | 53.6M / 63.7M / 57.7M |

两组第 2 轮摘要均未列出 `Malloc Large (empty)`，第 5 轮均列出 **1 个 region，virtual 7920K、resident/dirty 各 7904K、swapped 0K**。第 8 轮空载仍列出同样数值，播放组已不再列出。观察将共同的大块阶跃缩小到分配器的空闲大块区域这一线索，但该系统标签不是存活对象数，更不是播放器所有权或“无泄漏”的证明；未列出也不能自行换算成已回收字节。每次摘要约耗时 1.0–1.1 s，包含工具附加的观察成本。

所有进程资源试次仍完整保留：本轮释放后首末 footprint 空载 **+14745600 B**、播放 **+6668288 B**。没有因播放组数值较低而宣称优化，也没有删掉探索组后期页换出的记录。最终两组 sourceHash 均为 `5096bce4de74b30f16b5b3f18c1a17e0d271e5c52cd7574d11d649a8f74b48a9`；源码、依赖、原生制品、媒体和设备身份逐项核对一致。采样器仍按目录分别构建，保留各自 dylib 哈希，不声称整个二进制一致。[完整证据](../../../tool/playback_benchmark/macos-memory-category-observations.json)保留原始摘要及解析结果；原始运行目录归档在本计划忽略目录 `memory-categories/`。前台激活失败/native integration_test plugin 提示保留，成功的 driver 和日志不替代物理输出验收。

独立代码复核发现一项非阻塞测试入口细节：`test_memory_categories.py` 的 main guard 位于两个 runner 测试之前，直接执行文件只运行 6 项；本计划使用的 unittest discovery 已实际发现并运行全部 8 项新增测试（总计 45 项）。为保持本轮已冻结的源指纹，暂保留该细节，后续整理测试入口时修正。

### 分配调用栈探索（单独协议）

为继续追踪大块区域，额外运行两次空载诊断，均保持十轮与第 5 轮后查询，原始结果全部保留，不能与前两组比较性能。首次设置 `MallocStackLogging=1`，本机实际是 lite 模式，`malloc_history -highWaterMark` 退出 **249**，明确不支持历史峰值查询；另发现 Flutter 已废弃的 `--no-build` 在此入口仍执行第二次构建，因此该次环境也传给了构建子进程，不能描述成“仅应用启用记录”。未修改全局环境、SDK 或 entitlement。

依据本机 `man malloc` 和已安装 Flutter 源码，第二次先正常构建，再用 `--use-application-binary=<本次 Profile app>` 启动预构建应用，给 driver/应用后代设置 `MallocStackLogging=full`。日志确认只有一次构建。调用 `malloc_history PID -callTree -highWaterMark -noContent 'malloc[7m-9m]'`，截止 15 s；实际查询与 vmmap 合计约 **6.82 s**，历史查询退出 **0**。命令未请求对象内容；实际调用树仍包含其他尺寸分配，不能因传了过滤参数就声称只返回了 7–9 MiB 的记录。

完整历史运行 `macos-resource-20261007T083351Z` 的调用树显示 AppKit 的 **`NSPersistentUIWindowSnapshotter` 保存窗口快照路径中存在单次约 7.71M malloc 分配**，上游是 `captureAndWriteSnapshotForWindowNumber:forWindowID:waitUntilDone:`，下游进入系统 malloc；同一路径还涉及 IOSurface 和 Foundation 的大块数据页。完整约 36.6 MB 调用树已归档，提交证据只保存头部、相关连续行段、原文行号及全文件 SHA-256，未把无关大体积栈输出放入仓库。

两次开启栈记录的 vmmap 都增加了 Performance Tool Data 及“不计入 TOTAL”的注释，超出本次普通类别解析器支持的行格式；严格解析保持拒绝，原文保留，不计入最终两组 6/6 解析成功。

这为共同阶跃提供了一个具体的**系统窗口状态保存分配来源**，但高水位树不是该 `Malloc Large (empty)` 区域的地址级分配/释放历史，尚未建立一一对应；也没有证明播放器其他对象全部释放。不得把此线索改写成整个增长已归因或无泄漏。未禁用窗口恢复、改变分配器或调整生产缓存；此处命名来自实际系统栈，不作为产品代码依赖。

本项交付内存类别诊断和大块分配调用栈线索。完整 P08 Task1/2、长期资源预算与原生播放器对象生命周期仍开放。下一项优先建立大块区域地址与分配/释放历史的对应，并检查播放器会话/解码器/帧对象的存活情况；只对证实的生产缺陷实施修复。

## 2026-10-07 地址级分配/释放配对与原生对象存活窗口

起点 1f6a0f6。本项把上次的调用树线索推进到实际地址配对，并增加播放器存活/释放后的明确观察窗口。生产释放、缓存、窗口恢复策略均未改。先修正上次非阻塞测试入口问题：直接执行 test_memory_categories.py 实际从 6 项变为全部 8 项；标准 discovery 继续覆盖全部测试。

### 大块区域地址配对

初次空载诊断 20261007T094401Z（runId 均有 macos-resource- 前缀）10/10，298 个有效资源点：vmmap 中 7920K 的 Malloc Large (empty) 区域，基址查询已得到同范围的 VM_ALLOC，来源是 AppKit NSPersistentUIWindowSnapshotter。初次没有 malloc/free 配对；后来尝试查询内部地址时测试进程已退出，核对失败后没有执行任何进程检查，不能把未查询当作零分配或释放证据。

预先固定第二次协议：单独空载十轮，正常构建后启动预构建应用，仅 driver/应用后代设置 MallocStackLogging=full 和 MallocStackLoggingNoCompact=1；第 5 轮后验证精确 PID/可执行文件，采集不合并的区域，查询最多两块 7–9 MiB 空闲大块的基址及 +16/+32 KiB 内部地址，只读取分配历史元数据。

最终 20261007T095353Z：10/10，298 点，vmmap 与三个地址查询均退出 0，无额外错误。PID 9132 的结果：

| 层次 | 地址范围 | 字节数 | 实际证据 |
|---|---|---:|---|
| VM 区域 | 0x75a8c00000 至 0x75a93bc000（右端不含） | 8110080 | vmmap 与 VM_ALLOC 范围一致，分配栈来自 AppKit 窗口快照 |
| 区域内 malloc | 0x75a8c04000 至 0x75a93bb000（右端不含） | 8089600 | 同范围、同大小的 ALLOC 与 FREE 记录均存在，均为 AppKit 快照路径 |
| 查询时区域状态 | 同一 VM 区域 | virtual 7920K，resident/dirty 各 7904K | 系统仍标为 Malloc Large (empty) |

+16 KiB 与 +32 KiB 查询命中的是**同一次分配与释放**，不重复计算为两次释放。地址换算已验证系统历史里的右端包含值与 vmmap 右端不含值一致。该空载样本中的快照 malloc 已 free，而其 VM 区域仍由分配器保留；这是“free 了对象但进程内存未立刻下降”的直接证据。没有 VM_DEALLOC 或 footprint 完全回收证据，也不能把这块空载区域的归属外推为所有播放组增长的归属。

### 原生对象的明确观察窗口

新增 run_lifetime_probes.py，显式启用示例中的三个 20 s 等待窗口：第 1 轮加载并播放至媒体位置 2 s 后、释放之前（live），以及第 2/8 轮完成释放、卸载视图、删除临时媒体和普通 2 s 观察之后（disposed）。live 等待期间短素材可能播完，但播放器所有权仍保留。每个窗口仅运行一次 heap --noContent，10 s 截止，工具和应用标记均使用 macOS CLOCK_MONOTONIC_RAW 微秒。只有同 run/PID/试次/阶段的完整 begin/end，且命令起止全部在窗口内，才计为合格观察；下轮不会在等待期间创建实例。没有强制 GC、分配器清理或启用 MallocStackLogging。

最终 20261007T095123Z：10/10，383 个采样点，3/3 heap 命令成功并通过时间边界校验；各窗口约 20.003 s，命令分别耗时 2.943035 / 1.986764 / 1.995197 s。heap 的 timer/进程暂停开销属于此诊断协议，不能与原十轮协议作性能改善比较。

| heap 精确类型（均有 live 正例） | 第 1 轮释放前 | 第 2 轮释放后 | 第 8 轮释放后 |
|---|---:|---|---|
| YlApplePlayerHost、YlAppleSessionCoordinator、YlManagedPlaybackSession | 各 1 | 均未列出 | 均未列出 |
| YlOpenedMedia、YlVideoToolboxDecoder、YlFrameScheduler、YlPresentationCoordinator | 各 1 | 均未列出 | 均未列出 |
| YlManagedBufferLedger | 1 | 未列出 | 未列出 |
| YlManagedBufferLedger.Token | 191 | 未列出 | 未列出 |
| YlApplePlayerRegistry（插件级常驻） | 1 | 1 | 1 |

这些核心实例在本次两次释放后样本中未见滞留。证据保存 absent 为 not_listed/null，而非虚构零；容器类型名中含 YlApplePlayerHost 的 dictionary storage 仍列出，但它不是 Host 实例，不按字符串包含关系混计。heap 不保证识别全部 Swift/C/C++/GPU 分配，所以不能宣称整个播放器无泄漏、全部 native 内存已归还或长期稳定性已经完成。

### 验证、源身份与后续

新增 5 项窗口行为测试先因缺模块 RED，再通过共 **50/50 Python**；静态分析无问题，profile 实际播放十轮通过。测试覆盖缺标记、跨窗口、工具失败、时钟倒退/布尔值、身份混合及未声明阶段。异常 checkpoint 时钟读取可能中止余下试次；runner 会保留原始日志、计划次数并按不完整运行失败处理，不计未运行部分为成功，未做这条原生故障注入。

最终生命周期与地址诊断的 sourceHash 均为 c415317b67bf23b8a9521c9ef34bd4c36d349fe57fc1f345913b897619c40cca，源码/依赖/生产原生制品/媒体身份逐项验证一致；两种诊断协议不同，不合并为一个统计组。二者均 M1 / MacBookPro17,1 / macOS27.0(26A428)、arm64/profile、ac/nominal。所有有效资源点保留，timer 在检查工具运行时可能延后，不称为无间隙采样。[完整证据](../../../tool/playback_benchmark/macos-address-lifetime-observations.json)含三次运行、heap 原文和精确类型摘录、区域原文、ALLOC/FREE 栈、脚本及哈希；原始目录归档在本计划忽略目录 address-lifetime/。前台激活失败和 native integration_test plugin 提示仍不构成物理输出验收。

本轮完成该空载大块区域的归因与核心原生对象短循环存活观察，未发现能据此要求修改生产释放策略的缺陷。无需为消除该系统保留区域而禁用窗口恢复或强制清理分配器。完整 P08 Task1/2、首帧真实呈现/受控性能预算、长播、后台/多播放器及跨设备门槛仍开放；下一项进入预先固定时长与故障轨迹的长期资源观察，若出现新的持续增长，再按具体所有权证据定位。


## 2026-10-07 百轮加载/释放耐久观察

起点 `823cf22`，新增 `--profile-endurance` 入口，扩展已有本地 AVC/AAC Matroska 资源试验。运行前固定 **100 次顺序创建播放器，每次 idle 2 s、播放到媒体位置至少 2 s、独立限时清理、disposed 观察 2 s，250 ms 采样**；要求首个 idle 到末个 disposed 采样跨度至少 600 s，集成测试/驱动上限分别 900/1200 s。每轮仍限制 256 点。首个失败、超时或未确认清理会停止后续播放并将剩余试次标为 skipped；进程中断导致缺行则保留原定分母与日志并拒绝判为完成。冻结后的 `protocol.json` 在启动驱动前写入，并由最终结果记录哈希；没有重试、预热剔除或事后设定内存容差。

**这是重复加载/释放的耐久观察，不是连续播放一部十分钟长片。** 4 秒素材重复打开，每次仅播放到指定位置；没有后台、多播放器或内存压力操作，也没有 heap/vmmap/分配历史探针及强制 GC。本次未改生产播放、解码、缓存或释放策略。

执行命令：

```sh
python3 -B tool/playback_benchmark/run_resources.py --profile-endurance \
  /private/tmp/yl-resource-endurance-100 /Users/yy2021_8689/flutter/bin/flutter
```

实际运行 `macos-resource-20261007T101306Z`，PID `10099`，MacBookPro17,1 / Apple M1 / macOS 27.0 (26A428)，arm64 profile；源码指纹 `6b99e9bc839eb786409d46dd01d37f3f2ce3702458bb6fd99f65318fd78e5f2a`。驱动退出 0，**100 passed / 0 failed / 0 timeout / 0 skipped**，全部 managedFallback / hardware。采样跨度 **641.763245 s**，驱动命令总耗时 **666.913309 s**（包括构建/启动，不能当播放时长）；**3,104 点全部可用，全部 ac / nominal**。所有源文件、依赖、原生制品、媒体、采样库、冻结协议和日志哈希再次核验，完整 JSONL 与日志最终行逐项对应。应用未能自动置前的日志提示保留；本轮不验证物理画面/声音。

释放后端点首末相隔 **635.262817 s**，RSS 增加 **25,182,208 B（24.015625 MiB）**，physical footprint 增加 **27,115,520 B（25.859375 MiB）**。第 50→100 轮的两项端点均增加 **10,895,360 B（10.390625 MiB）**。以下固定每十轮列示，完整 100 个端点和所有阶段采样在证据中：

| 轮次 | 释放后 RSS (MiB) | 释放后 physical footprint (MiB) |
|---|---:|---:|
| 1 | 135.609375 | 52.532257 |
| 10 | 146.406250 | 66.344757 |
| 20 | 140.875000 | 59.657257 |
| 30 | 143.984375 | 62.844757 |
| 40 | 147.937500 | 66.704132 |
| 50 | 149.234375 | 68.001007 |
| 60 | 153.609375 | 72.297882 |
| 70 | 154.078125 | 72.844757 |
| 80 | 156.500000 | 75.266632 |
| 90 | 160.703125 | 79.547882 |
| 100 | 159.625000 | 78.391632 |

全阶段峰值 RSS **170,049,536 B**、footprint **96,470,048 B**；这些峰值包含播放/打开过程，不能与释放后端点混称。后半程仍有净增长，同时存在回落，**尚不能认定平台期，更不能宣称无泄漏**。本轮只有进程级账本，不能把新增字节分配给媒体对象、测试运行时或系统缓存；前一项已证明释放的 AppKit 特定分配也不能直接解释本轮全部增长。下一步优先在独立、预定的长周期对象生命周期观察中定位剩余增长，再决定是否修改生产代码。

新增 5 项协议准入/负例测试先 RED（缺函数/模式）后 **55/55 Python**；既有采样/独立清理 **15/15 Dart**，集成文件静态分析无问题。覆盖不足 100 轮、缺阶段/未知引擎、时长不足、身份混合/时钟重叠、失败后 skipped 分母，以及不兼容诊断模式在创建输出前拒绝。运行时 100 轮是实测通过，单元负例不冒充设备崩溃/挂起故障注入。

归档：[完整证据](../../../tool/playback_benchmark/macos-resource-endurance-observations.json) 内嵌最终结果、原始驱动/构建日志、冻结协议、100 轮观测与端点、源码/制品身份；原目录及本计划忽略工作区的 `endurance-100/` 保留原文件和采样库。`protocolCompleted=true` 只表示此次预定生命周期协议完成；`leakVerdict=null`、`performanceBaseline=false`、`budgetAdmission=false`。连续长片、更多时长、后台恢复、多播放器、低内存、其他设备/最低系统、真实呈现与正式性能目标仍开放，**完整 P08 Task1/2 未完成**。


## 2026-10-07 百轮对象生命周期与内存类别归因

起点 `3ee661f`，针对前一轮后半程 footprint 增长新增独立诊断入口：

```sh
python3 -B tool/playback_benchmark/run_lifetime_probes.py --long-cycles \
  /private/tmp/yl-long-lifetimes-100 /Users/yy2021_8689/flutter/bin/flutter
```

仍为 100 次顺序创建/播放/释放，运行前固定第 **1 轮 live、第 10/50/100 轮 disposed** 四个 **30 s** 窗口，每个窗口依次执行 `heap --noContent`、`vmmap -summary`，各自 10 s 上限及独立状态。每条命令先核查精确可执行文件路径，采集前后读取与应用标记一致的 `CLOCK_MONOTONIC_RAW`；只有完整位于同一 begin/end 窗口内的命令才合格。新 schema 2 / `long-cycle-v1` 拒绝旧三窗口标记混入；所有八项预定探针在未观察或失败时仍保留。旧无参数三窗口 heap-only 模式保留。没有启用分配栈日志、强制 GC、压力或生产配置修改。

运行 `macos-resource-20261007T103435Z`，PID **11641**，MacBookPro17,1 / M1 / macOS 27.0 (26A428)，arm64 profile，sourceHash **7f6148362ea18b7ef81278eae3ab41e96e2024790031fb0f451c80639be2c6ba**。**100/100 播放通过，8/8 探针捕获且合格，监控错误为空**。3216 个有效资源点全部 ac/nominal，无 unavailable；仍为 managedFallback/hardware。首末资源采样跨度 **731.497213 s**，驱动命令耗时 **787.769942 s**。live 等待在首轮采样内，三个 disposed 等待在相应最终资源行之后；最后窗口不在资源采样跨度内，故不能将这些数字称为连续播放时长或无间隙采样。

| 轮次/阶段 | 标记窗口 (s) | heap 采集区间 (s) | vmmap 采集区间 (s) | 两项都完整位于窗口内 |
|---|---:|---:|---:|---|
| 1 / live | 30.003571 | 2.138335 | 1.060045 | 是 |
| 10 / disposed | 30.003362 | 1.965474 | 1.026488 | 是 |
| 50 / disposed | 30.003592 | 1.998559 | 1.012363 | 是 |
| 100 / disposed | 30.003006 | 2.025599 | 1.022739 | 是 |

采集区间包括 `ps` 身份核查和工具执行时间；它是时钟准入边界，不是工具内部耗时统计。

### 对象与分配摘要

精确匹配 `Swift / yl_player_example` 类型名（不把包含该名称的 Dictionary storage 算成对象）。live 窗口可识别八类核心对象各 1 个：Host、SessionCoordinator、ManagedPlaybackSession、OpenedMedia、VideoToolboxDecoder、FrameScheduler、PresentationCoordinator、ManagedBufferLedger；Ledger.Token 为 182 个。三次 disposed 窗口均**未列出这九个类型**，插件级 PlayerRegistry 始终为 1 个。未列出记录为 `not_listed/null`，不能改写为零、全部已释放或全局无泄漏；heap 对 Swift/C/C++/Dart/GPU 的识别并不完整。

| heap 窗口 | 已分配节点数 | 已分配字节 | non-object 节点数 | non-object 字节 |
|---|---:|---:|---:|---:|
| 1 / live | 79,709 | 14,644,857 | 31,301 | 8,630,177 |
| 10 / disposed | 92,300 | 11,978,985 | 48,040 | 6,299,457 |
| 50 / disposed | 110,174 | 12,632,009 | 64,556 | 6,766,129 |
| 100 / disposed | 132,077 | 13,983,737 | 84,762 | 7,895,425 |

每份完整 heap 表的逐行 count/bytes 加总均与工具总数一致。第 50→100 轮仍增加 **21,903 个分配节点、1,351,728 B**，其中 non-object 增加 **20,206 个、1,129,296 B**；不能因核心类型未列出就忽略这些匿名分配，亦不能把 non-object 解读为“不是播放器内存”。其调用来源尚未确定。

### 系统类别与结论边界

下表保持 vmmap 原始四舍五入单位；`M/K` 不是精确字节值。分类驻留/脏页、malloc 已分配字节与 physical footprint 是不同账本，不做相减所有权推算。

| vmmap 窗口 | physical footprint | Untagged 脏页 | Malloc Small 脏页 | IOSurface 脏页 |
|---|---:|---:|---:|---:|
| 1 / live | 60.8M | 16.3M | 16.1M | 7504K |
| 10 / disposed | 60.3M | 24.5M | 17.1M | 0K |
| 50 / disposed | 70.4M | 32.5M | 19.2M | 0K |
| 100 / disposed | 79.7M | 39.5M | 21.4M | 0K |

第 50→100 轮主要脏页增长出现在 **Untagged 32.5M→39.5M** 和 **Malloc Small 19.2M→21.4M**；三次 disposed 的 IOSurface 均 0K 脏页、IOAccelerator 均 64K。所有窗口均未列出 `Malloc Large (empty)`，因此不能拿先前那块已释放的 AppKit 分配解释这次剩余增长。

本轮正常 disposed 资源端点首末 RSS 增加 **18,415,616 B（17.5625 MiB）**、footprint 增加 **16,187,392 B（15.4375 MiB）**，跨度 **695.207493 s**。它们与窗口内稍后执行的系统摘要不同步；新增等待和探针可能影响暂停、分配器和缓存行为，**不能将该增量比前一轮低解释为性能改善**。

本切片将调查范围缩小到未标注 VM 区域及匿名/小块分配，未定位到足以修改生产释放路径的缺陷。下一项优先用独立固定协议关联 **Untagged 的具体区域、Dart 堆 used/capacity/external 及原生匿名分配来源**；仅在工具实际支持并能验证同进程/时钟身份时记录，不能预设 Untagged 就是 Dart 堆。必要的空载对照单独运行，不从现有不同协议数字推断所有权。

新增 5 项长窗口/协议隔离、完整未观察分母及错误可执行文件拒绝测试先 RED 后 **60/60 Python**，Dart 集成文件静态分析无问题，实际新协议百轮已通过；未重复运行未改动的生产媒体套件。最终源码、依赖、原生制品、媒体、采样库、协议、全部原始探针/日志与应用可执行文件身份已核对。[完整证据](../../../tool/playback_benchmark/macos-long-lifetime-observations.json) 内嵌四份完整 heap 表、四份 vmmap 原文、逐行堆摘要、归档脚本、100 轮资源样本及全部指纹；原文件另存本计划忽略工作区 `long-lifetimes-100/`。

应用未能自动置前及 integration_test 原生插件提示均保留，不构成物理音画验收。`leakVerdict=null`、`performanceBaseline=false`、`budgetAdmission=false`；生产代码未改。连续长片、更长运行、后台/多播放器/低内存、其他设备与最低系统、真实呈现及正式基线仍未完成，**完整 P08 Task1/2 保持开放**。


## 2026-10-07 Dart 堆与 Untagged 地址关联

起点 `2768b11`，本项增加 `--memory-mapping`，在既定百轮四个 30 s 窗口内采集 heap、详细 vmmap 和 Dart group 堆元数据，共 12 项探针。生产/Dart 播放代码不变。Dart 端点只接受本次驱动日志里的字面回环 HTTP 地址，不走代理或重定向；前后 `getVM` 必须返回同一个 checkpoint PID 与 group 集合，逐 group 调用 `getIsolateGroupMemoryUsage`，不触发 GC、reset、堆快照或对象内容读取。读取非系统 group，**不包含 VM-service 等系统 group 的堆计数**。`externalUsage` 只是 embedder 向 VM 报告的关联外部内存，不能替代全部 native/GPU 账本。

详细 vmmap 保留 Untagged 的起止地址、访问属性与原始单位；地址相减只得到精确虚拟大小，不把四舍五入的驻留/脏页数字当精确字节。重复、重叠、格式未知或与摘要 regionCount 不一致的表格会被拒绝。每份采集都有独立 10 s 子进程上限和原始时钟区间。

### 失败路径修复与保留的尝试

独立复核发现 Important：旧 Dart 探针只在结束时输出，硬超时会丢失已完成请求；JSON 解析前也没有保留无效响应。初次 `macos-resource-20261007T110858Z`（sourceHash `755e183465172ea72f08c2a2de3168dfa4557bfe57a64f73dc62b44ba8b525cf`）在 10 个完成试次后主动中止，原定 100 次、缺少的 90 行保持未观察，不编造 skipped 或完整成功；结果仍为 failed，原始日志和已取得的六份探针原文保留。此中止是修复工具记录缺口的决定，不记为播放器自身故障。

修复后每次请求的 metadata、HTTP 状态和收到的数据块均先写入独立 JSONL 并 flush/fsync，再解析 JSON；无效 JSON 的原始字节保留，超限响应最多保存 1 MiB 前缀并显式记录 limit 事件。父进程即使硬终止子进程，也记录已写 journal 的哈希。真实本机回环测试先复现“getVM 已完成、下一请求悬挂时 kill 后证据丢失”，以及无效/超限响应丢失，再验证修复；首次受限环境不能绑定回环端口，随后在允许本地测试网络的环境完成有效 RED→GREEN。**共 66/66 Python 通过**，没有以 mock 成功替代这两项故障测试。

### 最终固定协议实测

```sh
python3 -B tool/playback_benchmark/run_lifetime_probes.py --long-cycles --memory-mapping \
  /private/tmp/yl-memory-mapping-final /Users/yy2021_8689/flutter/bin/flutter
```

最终 `macos-resource-20261007T111539Z`、PID **13802**，M1 / MacBookPro17,1 / macOS 27.0 (26A428)，arm64 profile，sourceHash **763eddf5857d63a898d7c75951b97765a19aeb43a44938ee26a7619788ee157c**。**100/100 播放通过、12/12 探针成功且完整位于各自窗口内**，监控错误为空。3224 个资源点均可用且全部 ac/nominal；managedFallback/hardware。资源首末跨度 **733.014149 s**，命令总耗时 **788.212431 s**；仍含诊断等待，不等于连续播放长片。四个 Dart 探针耗时 0.084584–0.090943 s（区间含进程身份核查），每组两次 getVM 身份匹配。

所有窗口识别同一非系统 group `isolateGroups/5690361082348171`（VM 报告名称 main.dart），指标如下，单位为精确字节：

| 窗口 | heapUsage | heapCapacity | externalUsage | Untagged 脏页（vmmap 原始单位） |
|---|---:|---:|---:|---:|
| 1 / live | 8,304,992 | 9,158,656 | 70,224 | 16.3M |
| 10 / disposed | 8,781,712 | 9,682,944 | 70,672 | 22.2M |
| 50 / disposed | 8,395,856 | 9,961,472 | 71,024 | 33.2M |
| 100 / disposed | 6,978,064 | 9,437,184 | 96 | 39.3M |

第 50→100 轮应用 group 的 heapUsage **8,395,856→6,978,064 B**，容量也从 **9,961,472→9,437,184 B** 回落，而 Untagged 脏页 **33.2M→39.3M**。这些同时段样本不支持“所测应用 group 堆使用量持续上升解释全部 Untagged 增长”的推断；不能据此排除系统 group、未报告外部内存或 native 分配。

### 已缩小到具体地址范围

四份详细表分别有 **48、49、52、52** 段 Untagged，数量与各自摘要一致。第 50/100 轮有 50 组相同边界，另有 2 组不再列出、2 组新列出；地址重用或重新映射未观测，因此“相同边界”不等于证明同一分配一直存活。

同一报告边界 **`0x11ba48000..0x11cd10000`（末地址不含）**，虚拟大小 **19,693,568 B**、`rw-/rwx / PRV`，各窗口脏页依次 **176K、2944K、12.1M、18.8M**。它是第 50→100 轮相同边界区域中最显著的脏页增长；另一段 `0x103f00000..0x103f80000` 为 192K→512K。这些原始单位均有四舍五入，不将相减结果写成精确分配字节，也不根据数值相似给地址指定 Dart 所有权。

核心八类原生播放器对象在 live 各 1、Ledger.Token 171；第 10/50/100 轮释放后均未列出这些九类，Registry 仍 1。heap 的全部已分配字节第 50→100 轮 **12,491,129→13,840,873 B**，non-object **6,724,769→7,850,497 B**，匿名分配仍增加，原生分配栈来源未测，不能宣布释放问题全部解决。

本轮 normal disposed 资源端点首末 RSS 增加 **17,793,024 B（16.96875 MiB）**、footprint 增加 **15,433,728 B（14.71875 MiB）**，跨度 **696.759872 s**。探针与端点不是同一瞬间，不与上一轮不同方法的数字计算优化比例。

下一项明确补齐两个证据缺口：**VM-service 等系统 group 的堆指标，以及该类大块 Untagged/匿名分配的地址级分配与释放历史**。先固定独立协议，验证工具支持和同进程身份，再按实际调用来源决定是否修改生产代码；本轮不预设这些区域归 Dart 或系统缓存所有。

### 归档与验收范围

[完整证据](../../../tool/playback_benchmark/macos-memory-mapping-observations.json)保留中止尝试与最终运行，含 100 轮资源、4 份 heap 全表、4 份详细 vmmap、4 份 Dart 返回及逐块 journal、40 项核心类型摘录、归档脚本和完整源/制品身份。最终源文件、依赖、原生制品、媒体、采样库、冻结协议、原始日志、journal 和应用可执行文件均核验；journal 重组的响应与 Dart 返回逐项一致，heap 行加总与工具总数一致。原文件另存忽略工作区 `memory-mapping-preliminary/` 和 `memory-mapping-final/`。预备与最终 sourceHash 不同，不能混成一个统计组。

前台激活失败和 integration_test 原生插件提示保留，不计物理画面/声音验收。生产代码未改，`leakVerdict=null`、`performanceBaseline=false`、`budgetAdmission=false`；系统 group、匿名分配来源、全局泄漏结论、连续长片、后台/多播放器/低内存、跨设备/最低系统和正式基线仍开放，**完整 P08 Task1/2 未完成**。

## 2026-10-07：系统 group 与大块 Untagged 分配栈（短程独立诊断）

本项选择先解决来源，而非再次扩大百轮次数。使用固定十轮 profile 播放，live 1、disposed 2/8 各 20 秒窗口；依次读取完整 vmmap、应用及系统 isolate group、三个地址的 malloc_history。目标在 live 1 固定为最大的 `Untagged / rw-/rwx / >=8MiB` 区域，同大小取最低地址；查询 base、base+16KiB、base+32KiB，每条历史查询限时 2 秒。目标不按后续增长重新挑选；地址重复不自动视为同一存活分配。协议在启动前写入且归档，所有探针必须完整落在同进程的成对原生时钟窗口内。

构建阶段不加 MSL，启动预构建应用时只给所拥有的进程树设置 `MallocStackLogging=full`、`MallocStackLoggingNoCompact=1`。工具开销会影响进程资源；`Performance Tool Data` 的 vmmap `not counted in TOTAL below` 注解被显式保留，不能将本项与普通运行相减计算优化比例。系统 group 查询为显式选项，旧的应用 group 默认行为保留；分别检查两类 group，拒绝跨类重复 ID 和身份变化，缺失/不支持均不可当零，无强制 GC，响应逐块持久化。

初次 `macos-resource-20261007T114335Z`、PID 15255，十轮播放均通过，但仅 **5/15 探针合格**。live vmmap 出现单独的 `Untagged (reserved)`、32K、`SM=NUL` 行，原严格解析器将其混入实际分配分类并拒绝；目标保持 null，九条历史查询均 unavailable。该运行完整保留为不完整诊断，不补造所有权证据，也不重写当时的源码身份。新增回归测试先复现 ValueError，随后仅排除该独立 reserved 分类，摘要仍保留其信息。

独立复审还发现监控器可能读到日志正在追加的半行并永久退出。用真实临时文件分两次追加 checkpoint 复现：旧实现捕获 0 次，预期 2 次；修复后等待未换行尾部，下一轮读取完整行，已换行的非法 JSON 仍失败。包含该行为回归、系统 group、MSL 注解和原有 HTTP 硬终止/无效响应保留测试，**73 项 Python 测试通过**。没有 Dart 或生产代码变更。

### 最终结果与直接地址证据

最终 `macos-resource-20261007T114805Z`、PID **15908**，M1 / MacBookPro17,1 / macOS 27.0 (26A428)，arm64 profile，sourceHash **4fd2499df090d2f59ef62a861b9242f1ea41fc31d7ed5d3df3acae27e50a4e81**。**10/10 播放通过，15/15 探针完整位于各自窗口内**，监控错误为空。三个窗口分别 20.003345、20.004550、20.004125 秒；单条探针耗时 0.084943–1.189188 秒。388 个资源点全部可用、ac/nominal，managedFallback/hardware；首末点跨度 124.044853 秒，命令耗时 150.149896 秒。跨度包含诊断等待，不是连续长片或无间断资源采样。

目标范围 **`0x11a8dc000..0x11bba4000`（末地址不含）**、**19,693,568 B** 虚拟内存。九份历史输出都包含相同的单条 `VM_ALLOC`，工具显示末地址为包含式 `0x11bba3fff`，换算后与 vmmap 的完整范围精确相等。直接调用栈为：

```text
vm_map
  dart::GenericMapAligned
  dart::VirtualMemory::AllocateAligned
  dart::SampleBlockBuffer::SampleBlockBuffer
  dart::Profiler::StartLocked / SetConfig / Init
  dart::Dart::DartInit
  Flutter engine launch
```

因此，本次精确映射的分配来源已定位到 **Dart Profiler 的 SampleBlockBuffer**。九次查询是同一范围在三个地址/三个窗口的重复证据，不是九次不同的分配。该范围各窗口脏页为 **192K → 1120K → 2896K**，虚拟边界相同。输出未捕获该范围的 FREE/VM_DEALLOC，不将其解释为已释放，也不从缺少释放事件推断泄漏、完整生命周期连续性或进程结束后的回收。

前次百轮进程里另一个 19,693,568 B 范围的形状与此相似，但没有它自己的分配栈；**不把本次所有权结论直接覆盖到前次地址**，也不将所有 Untagged 或匿名 malloc 都归给 Profiler。当前证据足以将 Profiler 测量开销列为后续控制变量。

### 应用与系统 group 指标

本次三个窗口都分别识别应用 group `isolateGroups/157536982132139`（main.dart）和系统 group `isolateGroups/2578849968304378`（vm-service），各次前后 getVM 身份一致。以下都是精确字节，按顺序查询，非原子快照：

| 窗口 | group | heapUsage | heapCapacity | externalUsage |
|---|---|---:|---:|---:|
| 1 / live | application | 8,262,496 | 9,158,656 | 70,224 |
| 1 / live | system | 7,524,448 | 8,634,368 | 228,848 |
| 2 / disposed | application | 7,876,048 | 9,158,656 | 69,168 |
| 2 / disposed | system | 8,244,528 | 9,158,656 | 232,512 |
| 8 / disposed | application | 7,815,008 | 9,158,656 | 800 |
| 8 / disposed | system | 7,186,512 | 8,634,368 | 2,208 |

系统 group 用量在本次短窗口中并非持续上升；这不证明长期稳定，也不覆盖 Dart VM 所有 native 内存。vmmap 的整个 Untagged 脏页依次 16.2M、20.4M、21.2M；Performance Tool Data 脏页均 49.0M，明确 `excludedFromTotal=true`。这些工具原始单位保留四舍五入，不冒充精确字节。

### 归档、裁定与后续

[完整证据](../../../tool/playback_benchmark/macos-system-address-observations.json)约 11.04 MB，保留初次不完整诊断和最终全部日志、vmmap、RPC journal、九份完整历史栈、协议、启动包装器、归档脚本、资源与源码身份。最终源码、依赖、制品、媒体、采样库、应用二进制、协议、原始文件和 RPC journal 均核验；逐块 journal 重组与响应相等，资源原始日志/JSONL/结果和重算摘要一致。原文件另存忽略工作区 `system-address-preliminary/`、`system-address-final/`，两组不同 sourceHash 不混并。

裁定：优先使用短程有界归因查明本次分配来源；代价是本项不能关闭长期增长验收。复审的日志半行问题按会丢失后续观测的影响升级为 Important，并在同一修复轮次完成真实 RED→GREEN。没有凭此修改播放器释放逻辑或关闭生产 Profiler。

下一项为**验证本地工具支持后冻结 Profiler 开/关的独立对照协议**，再区分测量开销与仍未归因的匿名增长；不能把移除观测开销算作播放器优化。连续长片、后台/多播放器/低内存、跨设备/最低系统、物理输出与正式基线仍开放，**完整 P08 Task1/2 未完成**。前台激活失败及 integration_test 原生插件提示保留，`leakVerdict=null`、`performanceBaseline=false`、`budgetAdmission=false`。

## 2026-10-07：Profiler 运行时开关对照（独立短程协议）

本地 Flutter 的 `desktop_device.dart` 在桌面启动环境中直接添加 `enable-dart-profiling=true`；本地 engine 的 Dart 参数允许表也没有 `--no-profiler`。因此没有将命令行意图当作实际关闭证明，也没有修改 SDK。`vm_service` 文档支持运行时 `setFlag(profiler)`，同时明确停止采样可能不释放 sample buffer。本项采用该接口，并要求真实状态回读；相关本地源码、路径和哈希随证据归档。

固定协议先运行 on、再运行 off，各为一个新进程、十轮 profile 播放，无 MallocStackLogging、无 GC；三个 20 秒窗口仍为 live 1、disposed 2/8。在 **第一个播放器已加载后的 live 1**，两组都执行相同的 getVM/getFlagList/setFlag/getFlagList/getVM 流程；后两窗口只读 Profiler 状态，然后依次采集详细 vmmap 和应用/系统 group 内存。这不是从进程启动时就关闭 Profiler，也不预设已经分配的缓冲区会释放。

只允许所拥有的测试进程、literal loopback 服务、精确 `profiler=true/false` 设置；默认 RPC 路径仍不能修改标志，任意其他标志、值或额外参数都在请求前拒绝。已有每响应 1MiB、每次读取 2 秒、子进程 10 秒上限及原始 journal 持久化继续适用。每组九个计划探针全部保留；setter Success 不够，必须回读符合预期、身份一致、完整位于时钟窗口内。最终对照要求两组不同 PID，源码、依赖、原生制品、媒体、设备/架构、build mode 和 workload 协议一致。采样库 install name 带新输出路径，其二进制哈希独立记录，源码纳入共同 sourceHash；每组应用可执行文件指纹在下一次构建前记录。

### 预备失败与身份校验修正

预备 on `macos-resource-20261007T120839Z` / PID 16744、off `macos-resource-20261007T121109Z` / PID 17392，各 **10/10 播放通过**，但分别只有 **0/9、3/9 探针合格**。on 的 setter 和前后 true 回读都成功，同一 PID、相同应用/系统 group 的两次 getVM 却给出 `startTime=1791374942345` 与 `1791374942344`，相差 1 毫秒；原先精确相等校验按规则拒绝。off 已成功设置 false，后续身份检查也遇到该问题。两组均保留为不完整对照，未将其升级为正式结果。

用完整真实 RPC 回放复现 RED，再以严格 PID + 非空应用 group / 完整系统 group ID 列表作为前后和跨窗口身份，保留原始两次 startTime，不使用任意时间容差。缺失、类型错误、重复、跨类重复和 group 变化仍拒绝。真实回放 GREEN，相关新增回归与全部 Python 测试 **78 项通过**。没有 Dart、生产播放器或 SDK 变更。

### 正式对照结果

正式共同 sourceHash 为 **f83a00f753da7918bdb6a7175cfc24347b4e6326d77a8d25dda544df6b89ed68**，698 项源码指纹相同；M1 / MacBookPro17,1 / macOS 27.0 (26A428)、arm64 profile、managedFallback/hardware。两组分别：

| 条件 | runId | PID | 播放 | 窗口内探针 | 资源点 | 首末点跨度 | 命令耗时 |
|---|---|---:|---:|---:|---:|---:|---:|
| on | macos-resource-20261007T121601Z | 18181 | 10/10 | 9/9 | 388 | 123.869086s | 148.559794s |
| off | macos-resource-20261007T121830Z | 18598 | 10/10 | 9/9 | 389 | 124.205368s | 149.187114s |

全部资源点可用、ac/nominal，监控错误为空，`matchedConditions=true`；源码、依赖、原生制品、媒体、设备/架构、build mode、次数及 workload 协议匹配。跨度包含检查点等待及采样间隔，不是连续长片。on 的三次实际回读均 true；off 在 live 1 从 true 设置为 false，disposed 2/8 均保持 false，后两次只读没有重新设置。六个窗口都通过精确 PID/group 前后和跨窗口校验。

每组详细 vmmap 都有一个与上一项目标同大小、19,693,568 B、`rw-/rwx` 的 Untagged 范围。on 是 `0x11de60000..0x11f128000`，off 是 `0x11b01c000..0x11c2e4000`，末地址均不含。下面保留工具四舍五入后的显示单位：

| 条件 / 窗口 | 该大小区域脏页 | 整个 Untagged 脏页 | Malloc Small 脏页 | 进程 footprint |
|---|---:|---:|---:|---:|
| on / 1 live | 192K | 16.5M | 15.8M | 61.2M |
| on / 2 disposed | 1136K | 21.0M | 16.7M | 65.2M |
| on / 8 disposed | 3056K | 22.0M | 17.0M | 58.1M |
| off / 1 live | 176K | 16.5M | 15.8M | 61.1M |
| off / 2 disposed | 176K | 20.0M | 16.8M | 64.2M |
| off / 8 disposed | 176K | 19.1M | 17.0M | 55.6M |

**本次关闭采样后，该大小映射仍存在，三个窗口脏页保持 176K；开启组则继续增加。** 结合上一项直接分配栈，这支持 Profiler 采样是此类增长的一个来源。本次没有 MSL 栈，不凭大小相同宣布跨进程分配身份相同，也不证明缓冲区完整生命周期或全部 Untagged 所有权。

应用/系统 group 的 heapUsage 如下，精确字节；heapCapacity、externalUsage 与完整原始响应保存在证据中，未合并成全进程内存账本：

| 条件 / 窗口 | application heapUsage | system heapUsage |
|---|---:|---:|
| on / 1 live | 8,262,768 | 7,790,304 |
| on / 2 disposed | 7,941,888 | 8,721,360 |
| on / 8 disposed | 7,815,040 | 7,858,784 |
| off / 1 live | 8,263,104 | 7,790,720 |
| off / 2 disposed | 7,941,024 | 8,722,816 |
| off / 8 disposed | 7,814,896 | 7,861,776 |

normal disposed 第 1→10 轮端点，on 的 RSS/footprint 增量分别 **6,553,600 / 5,668,864 B**，跨度 97.585493 秒；off 分别 **2,785,280 / 2,293,760 B**，跨度 97.917757 秒。关闭组仍有增长，两组 Malloc Small 也都从 15.8M 到 17.0M。端点与 vmmap 不是同一瞬间；固定顺序、单一对照、OS 缓存不受控及诊断自身开销仍在，因此不报告播放器优化比例、稳定平台或无泄漏结论。

### 验证与下一项

[完整证据](../../../tool/playback_benchmark/macos-profiler-control-observations.json)约 16.54 MB，包含预备不完整对照、正式两组、全部资源/窗口原始记录、vmmap、FlagList/setFlag 返回、逐块 journal、冻结协议、每组应用指纹、本地 SDK 源码证据及归档脚本。重新计算资源摘要、重放控制与内存 RPC、重组 journal，并核验源码/依赖/制品/媒体/采样库/协议/日志哈希和全部 18 个窗口资格；最终代码全套 **78 项 Python 测试通过**。每组构建产物身份单独保留，不声称应用二进制逐字节相同。

裁定：使用实际可回读的运行时控制作为本轮对照；代价是不能覆盖启动时禁用及长期/连续播放。启动时间保留为观测字段，用严格 PID/group 身份替代不可靠的精确时间戳相等要求。生产、SDK 和 Dart 代码均未改，去掉观测开销不计为播放器优化。

下一项固定**Profiler 关闭后的百轮资源与生命周期复核**，确认晚期剩余增长的类别，再决定是否需要继续追查匿名分配；不把本次短程曲线外推到百轮。连续长片、后台/多播放器/低内存、物理音画、跨设备/最低系统和正式基线仍开放，**完整 P08 Task1/2 未完成**。前台激活失败及 integration_test 原生插件提示保留；`leakVerdict=null`、`performanceBaseline=false`、`budgetAdmission=false`。

独立复审核验 67 份嵌入原始文件、698 项源码指纹、12 份 RPC journal 重组、六份 vmmap、18 个窗口资格、资源摘要和报告数值；Critical / Important / Minor 均无遗留。本切片可提交，不扩大全部功能或 P08 完成范围。

## 2026-10-07：Profiler 关闭后的百轮资源与生命周期复核

本项将上一项已验证的运行时 Profiler 关闭方式用于既有百轮协议。独立新进程，100 次加载/播放/释放，资源首末点至少相隔 600 秒；测试上限 900 秒、命令上限 1200 秒。live 1、disposed 10/50/100 各固定 30 秒窗口，每个窗口依次读取 Profiler 状态、原生 heap（不读对象内容）、详细 vmmap、应用/系统 Dart group 指标，共 16 个计划探针。根协议和资源身份/协议均在启动前冻结。

仅 live 1 在第一个播放器加载后设置 `profiler=false`，后续三次只读并核对实际状态。PID/group 身份必须在单次和跨窗口保持一致；raw startTime 原样保留。每个探针必须完整落入对应原生时钟窗口；所有播放成功、最低跨度通过、16 个探针都合格才完成该诊断。采样和探针的缺失、超时或失败保留，不合成零值。不启用 MSL 或强制 GC，未更改 SDK、Dart 或生产播放器。

新增测试先因缺少长模式失败，再通过：验证失败保留全部 16 个计划探针、四个 schema 2 窗口只进行一次设置且每次先验状态、禁止开启组及冲突模式。**81 项 Python 测试通过**，原短程模式保留；独立启动前代码复审无 Critical / Important / Minor。该运行用于百轮加载/释放观察，不代表连续长片、从启动禁用 Profiler、连续监视 flag 或正式性能基线。

### 百轮结果与剩余增长

本次 `macos-resource-20261007T130136Z` / PID **19992**，sourceHash **94c957eb9453da561b83c0bd0e1f1687e8f3cfdc939b94b591b877b5ff85fd55**，699 项源码指纹；M1 / MacBookPro17,1 / macOS 27.0 (26A428)、arm64 profile、managedFallback/hardware。**100/100 播放通过，16/16 窗口探针合格**，3224 个资源点均可用、ac/nominal，监控错误为空。首末资源点跨度 **733.228443 秒**，命令耗时 **789.272953 秒**。跨度包含诊断等待和采样间隔，最后 disposed 100 检查点在最后一条普通资源记录之后，不将二者当作相同采样终点或连续长片。

live 1 实际 flag 从 true 设置并回读为 false；disposed 10/50/100 只读前后均为 false，四个窗口 PID/应用及系统 group 身份一致。这是四次合格状态观察，不是窗口之间的连续 flag 监控。

| 窗口 | 19,693,568 B 区域脏页 | 整个 Untagged 脏页 | Malloc Small 脏页 | vmmap footprint | application heapUsage (B) | system heapUsage (B) |
|---|---:|---:|---:|---:|---:|---:|
| 1 live | 160K | 16.6M | 15.8M | 61.0M | 8,297,312 | 7,740,944 |
| 10 disposed | 160K | 19.2M | 16.8M | 55.3M | 7,948,736 | 7,725,168 |
| 50 disposed | 160K | 21.0M | 18.2M | 58.7M | 7,334,544 | 7,064,560 |
| 100 disposed | 160K | 19.7M | 20.5M | 58.9M | 7,800,576 | 7,645,200 |

该 Untagged 范围四次均为 `0x11d660000..0x11e928000`（末地址不含）、`rw-/rwx`，关闭后脏页在检查点保持 160K。它与此前定位的 Profiler 缓冲区大小相符，但本次没有 MSL 分配栈，不用形状替代所有权或完整生命周期证据。vmmap 单位保留工具四舍五入结果；Dart 指标为分组顺序查询的精确字节，不是原子快照或完整 native 内存账本。

普通 disposed 第 1→100 轮端点 RSS **150,519,808 → 147,816,448 B**、footprint **66,634,784 → 61,326,368 B**，差值分别 **−2,703,360 / −5,308,416 B**，跨度 696.940826 秒。第 50→100 轮仍分别增加 **704,512 / 262,144 B**。早期峰值回落不代表对象数量稳定或无泄漏，普通端点也不与稍后 heap/vmmap 取样合并。

live 中八个核心 Host/会话/解码/调度/账本类型各列出一个，Token 180 个；disposed 10/50/100 均未列出这些类型，registry 四次均列出一个。未列出保持 `not_listed` / null，不改写成零或已证明释放。

| 窗口 | 全部 heap 节点 / 字节 | non-object 节点 / 字节 | FlutterEngineHandlerInfo 数量 / 字节 | Swift.StringStorage 数量 / 字节 |
|---|---:|---:|---:|---:|
| 1 live | 79,710 / 14,704,489 | 31,295 / 8,689,713 | 26 / 832 | 151 / 13,712 |
| 10 disposed | 92,352 / 11,822,377 | 48,048 / 6,138,273 | 179 / 5,728 | 299 / 44,544 |
| 50 disposed | 110,294 / 12,751,209 | 64,639 / 6,882,145 | 859 / 27,488 | 979 / 184,064 |
| 100 disposed | 132,226 / 14,091,641 | 84,879 / 8,000,545 | 1,709 / 54,688 | 1,829 / 358,464 |

### 已有源码支持的通道清理假设

第 10→50 轮 `FlutterEngineHandlerInfo` 增加 **680 个**，第 50→100 轮增加 **850 个**，两段都精确对应 **每轮 17 个**；StringStorage 同期数量增量一致，但尚未证明这些字符串逐个属于通道名称。后半程 non-object 仍增加 20,240 个 / 1,118,400 B，不能把全部匿名增长归给通道。

现有源码路径与该计数吻合：registry 的 `didDispose` 移除 host 后，插件分别调用播放和 DRM 生成接口的 `setUp(api:nil)`。生成代码分别为 14 个和 3 个通道创建新的 `FlutterBasicMessageChannel`，再设置 nil handler。新实例没有原注册连接号；本地 `FlutterChannels.mm` 因此走 `setMessageHandlerOnChannel(...nil)` 路径，而 macOS `FlutterEngine.mm` 的该路径仍向 `_messengerHandlers` 写入新的 `FlutterEngineHandlerInfo`。持有原连接号时的 `cleanUpConnection` 则会移除记录。每个播放器独立 suffix 使这些键不会在后续播放器中复用。

这是**有源码与数量对应证据的卸载记录保留假设**，需要定向连接清理回归测试和修复后相同协议验证因果关系；不等于已证明 host 泄漏、字符串所有权或所有 RSS/匿名分配来源。生产播放器、生成代码和 SDK 在本切片均未修改。

### 归档、裁定与下一项

[完整证据](../../../tool/playback_benchmark/macos-profiler-off-long-observations.json)约 **14.41 MB**，保留 33 份原始文本文件、百轮资源记录、四份 heap/详细 vmmap、全部控制与内存 RPC/journal、两个冻结协议、应用/源码/依赖/制品/媒体指纹、相关本地 Flutter 与插件源码摘录和归档校验脚本。全部日志/JSONL/结果一致，重算摘要、重放 RPC、逐块重组 journal、重解析 heap/vmmap 和 16 个时钟窗口资格通过；源码身份再次核验。完整原文件另存忽略工作区 `profiler-off-long-final/`。

裁定：关闭已识别的采样干扰后，优先处理具有计数和源码路径支持的通道连接清理候选，再评估剩余匿名增长；不把本次与不同插桩的旧百轮运行计算为优化比例。下一项先建立连接注册/卸载行为回归，修复实际连接清理，再按本次协议验证。

连续长片、后台/多播放器/低内存、物理音画、跨设备/最低系统、正式呈现与性能基线仍开放，**完整 P08 Task1/2 未完成**。前台激活失败及 integration_test 原生插件提示保留；`leakVerdict=null`、`performanceBaseline=false`、`budgetAdmission=false`。

独立最终复审核验 33 份原始文件、699 项源码指纹及其他身份、33 个 RPC 响应/8 份 journal、16 个窗口和四份 heap/vmmap，报告数值一致；Critical / Important / Minor 均无遗留。本诊断切片可提交，连接清理修复效果和完整 P08 验收保持开放。

## 2026-10-07：macOS 通道连接清理修复

上一项百轮观察的 17 条/轮处理记录增长已用真实 macOS FlutterEngine 回归复现。测试通过实际插件注册、生成消息编解码、工厂 create 和异步 dispose 路径，只替换 Dart 传输入口与纹理注册边界；计数来自测试专用 KVC 读取的实际 engine handler 字典，不在生产使用私有接口。三个测试在旧实现全部失败：一次 dispose 后 18 条而非工厂的 1 条；两播放器 detach 后 35 条而非 0；释放一个播放器时无法保留并隔离新的外部同名连接。

修复仅在 macOS 的 host 注册边界增加连接所有权适配器，记录注册返回的连接号。生成接口以 nil handler 卸载时，按原连接号调用公开的 `cleanUpConnection`，并从适配器移除记录；重复卸载不再创建 nil-handler 记录。插件保留同一 messenger 供 factory detach 使用。原连接过期时不会删除外部更新后的同名连接；其他播放器继续处理命令。iOS 仍直接使用原 registrar messenger，出站回调仍通过既有平台线程适配器，未改生成代码、SDK 或媒体解码策略。

定向三个测试 **RED 3 failed → GREEN 3 passed**，覆盖连续三次 create/dispose、两个存活播放器 detach/重复 detach、外部新连接和存活 peer 命令。当前测试发现校验更新为 macOS 590 / iOS 669；完整 macOS 原生回归随后运行，结果见下文。

修复后资源验证预先沿用上一项 `--long-off` 根协议与资源协议：独立 profile 进程、100 轮、四个 30 秒窗口、16 个探针、live 1 设置 false 后只读、无 MSL/强制 GC、至少 600 秒。以 `69c9191` 已归档源 `94c957eb9453da561b83c0bd0e1f1687e8f3cfdc939b94b591b877b5ff85fd55` 为前观察，核对协议/设备/依赖/制品/媒体与诊断脚本身份，仅允许修复源码和回归测试源码发生预期变化。固定前后次序、单次运行和 OS 缓存不受控，故仅据匹配的对象计数评估本缺陷，不计算全进程性能优化比例或整体无泄漏结论。

完整 macOS 原生结果为 **589/589 passed，0 failed、0 skipped**，运行身份与条件编译后的规范清单逐项相等。源码发现计数 590 包含一个仅 iOS 条件下编译的测试，不能当作少跑一项。原生工具脚本 7 项通过；首次在沙箱中被 `ps` 权限限制的 1 项环境错误，经允许进程查询后重跑通过。既有编译警告（弃用、Swift 并发、XCTest 最低系统版本等）保留，不将本机通过宣称为最低 macOS 版本验收。

### 修复后百轮结果

修复后 `macos-resource-20261007T134446Z` / PID **22758**，sourceHash **2643943e34361d31f024f20447a9c40114d71afbb256f148a01ab40df5c44b6b**。**100/100 播放、16/16 窗口探针通过**，3218 个资源点全部可用、ac/nominal，监控错误为空；首末资源点跨度 **731.356601 秒**，命令耗时 **808.371982 秒**。与修复前相同 M1 / MacBookPro17,1 / macOS 27.0 (26A428)、arm64 profile、managedFallback/hardware；根协议与资源 workload 协议逐项相等，依赖、原生制品、媒体和诊断脚本一致。699 项源码指纹中仅插件实现与例子中的新增原生回归测试文件不同，实际差异与哈希均入档。

live 1 设置后实际回读 false，disposed 10/50/100 前后均为 false，四窗 PID/应用及系统 group 身份一致。最后窗口仍位于普通资源序列结束之后；跨度不是连续长片时长。

| 释放后检查点 | 修复前 HandlerInfo 数量 / 字节 | 修复后 HandlerInfo 数量 / 字节 | 修复前 StringStorage 数量 / 字节 | 修复后 StringStorage 数量 / 字节 |
|---|---:|---:|---:|---:|
| 10 | 179 / 5,728 | 9 / 288 | 299 / 44,544 | 129 / 9,664 |
| 50 | 859 / 27,488 | 9 / 288 | 979 / 184,064 | 129 / 9,664 |
| 100 | 1,709 / 54,688 | 9 / 288 | 1,829 / 358,464 | 129 / 9,664 |

两次 live 1 的 HandlerInfo 都为 26 个 / 832 B，StringStorage 都为 151 个 / 13,712 B。修复后释放检查点的 HandlerInfo 不再每轮增加 17 条，三个检查点均保持 9 条；结合真实引擎回归 RED→GREEN，支持**本插件 macOS host 通道卸载记录保留缺陷已修复**。9 条包含仍在使用的工厂及引擎/测试通道，不以全进程归零为目标。StringStorage 同时稳定是相关改善，不冒充逐字符串所有权证明。

| 修复后窗口 | 全部 heap 节点 / 字节 | non-object 节点 / 字节 | Malloc Small 脏页 | Untagged 脏页 | vmmap footprint |
|---|---:|---:|---:|---:|---:|
| 1 live | 79,886 / 14,615,481 | 31,387 / 8,699,761 | 15.9M | 16.6M | 61.0M |
| 10 disposed | 91,897 / 11,630,377 | 47,974 / 6,092,257 | 16.7M | 19.2M | 55.0M |
| 50 disposed | 109,912 / 12,455,705 | 64,715 / 6,773,297 | 18.3M | 21.5M | 58.9M |
| 100 disposed | 130,040 / 13,583,337 | 84,851 / 7,901,089 | 19.2M | 20.0M | 58.3M |

八个核心 Host/会话/解码/调度/账本类型在 live 各列出一个，Token 187 个；三次 disposed 均未列出，registry 仍一个，继续保留 `not_listed` / null。19,693,568 B Untagged 范围为 `0x119248000..0x11a510000`（末地址不含），四次脏页均 176K；本次仍无该地址的分配栈或完整生命周期证明。

应用 group heapUsage 四窗依次 **8,312,096 / 7,948,448 / 8,146,992 / 7,307,328 B**，系统 group 为 **7,742,016 / 7,726,048 / 7,064,560 / 7,644,160 B**，其余内存指标保留原始精确值。普通 disposed 第 1→100 轮 RSS **150,585,344 → 148,439,040 B**、footprint **66,667,528 → 60,605,448 B**，差值 **−2,146,304 / −6,062,080 B**，跨度 695.085750 秒；第 50→100 轮 RSS 增加 262,144 B，footprint 减少 737,280 B。它们与稍后的 vmmap/heap 不是同一瞬间，不能相减建立对象所有权账本。

仍有未归因增长：后半程 non-object 增加 **20,136 个 / 1,127,792 B**，Malloc Small 脏页也增加。故本项修复不关闭全部匿名分配、总体无泄漏或正式性能基线，也不把一次前后运行的 RSS/footprint 差异写成优化百分比。

### 证据与后续边界

[修复及百轮证据](../../../tool/playback_benchmark/macos-channel-cleanup-observations.json)约 **15.17 MB**，包括 33 份百轮原始文本文件、10 份原生 RED/GREEN/完整回归日志与运行清单凭据、两个冻结协议、源/依赖/制品/媒体/应用指纹、前观察文件哈希和逐项条件比较、源码摘录及归档脚本。资源日志/JSONL/摘要重算、heap/vmmap 重解析、RPC 回放和逐块 journal 重组、16 个时钟窗口与最终源码身份均通过；原始文件另存忽略工作区 `channel-cleanup-final/`。原生 xcresult 保留在本机 `/private/tmp/yl-channel-cleanup-{red,green,full}.xcresult`，可携带摘要与完整运行身份已入档。

下一项为**修复后剩余 non-object 分配的有界栈归因**，先冻结短程、地址/分配选择和工具开销协议，再用证据决定是否需要下一处生产修复；不重新打开已解决的通道记录问题，也不为了 RSS 表面回落增加强制 GC 或任意缓存清空。连续长片、后台/多播放器/低内存、物理音画、跨设备/最低系统、iOS 本次运行、DRM 授权验收、正式呈现和性能基线仍开放，**完整 P08 Task1/2 未完成**。

独立最终复审通过：核验 33 份百轮原始文件、10 份原生测试凭据、699 项源指纹及其他身份、33 个 RPC/8 份 journal、16 个窗口与四份 heap/vmmap，前后条件与报告数字一致。Critical / Important / Minor 均无遗留，可提交本次限定修复；上述剩余验收边界不变。

## 2026-10-07：修复后 non-object 分配调用树归因

本项依照上一项剩余增长结论，先固定独立短程协议：十轮 profile 创建/播放/释放，live 1、disposed 2/8 各 20 秒，依次采集 Profiler 控制/回读、`heap --noContent`、`malloc_history -callTree -noContent -invert -ignoreThreads non-object`。选择整个 non-object 类别，不事后挑选增长地址；系统工具本机手册明确支持此类别过滤。复用已有先构建再以 MallocStackLogging=full、MallocStackLoggingNoCompact=1 启动的包装器，原始启动输出和环境声明均保留。

仅 live 1 在首次加载后设置 false，后两窗只读状态；精确 PID、应用/系统 group 和原生时钟窗口继续校验。调用树单次上限 8 秒，其余控制/heap 上限 10 秒；即使工具成功，超出窗口仍不合格。九个计划探针缺失、超时和部分输出均入档。捕获成功只代表有同 PID 的有界工具输出，不能自动声明堆栈覆盖、所有权或不存在泄漏。MSL 自身开销使该诊断不能直接与此前百轮内存值算优化比例，也不作连续长片或正式基线。

新增四项测试先因缺少功能失败，再验证超时原始保留、禁止无关进程、九个未观测分母和独立资源协议守卫；完整 **85 项 Python 测试通过**。没有生产播放器、Dart、生成代码或 SDK 修改。

预备运行 `macos-resource-20261007T235337Z` / PID 34158 为10/10播放、9/9原始窗口采集合格，但三份调用树均只有标题/映像表而没有栈行，**归因不合格**。同窗 heap 明确写出从分配栈推导出的类型名，原 non-object 筛选不能覆盖这些已改名节点；空树不代表没有匿名分配。原协议/源码/应用身份和完整原始输出已保留。用真实空树形状回归先观察失败，再拒绝无栈行输出，并冻结 v2 全部分配类别 `.*` 的新协议；后续从完整树与 heap 类型表关联来源，不事后限定为已看到的 Dart Timeline 名称。

### 最终调用树与来源证据

v2 独立运行 `macos-resource-20261007T235746Z` / PID **34777**，sourceHash **446d4e7d4d936b990c1cf7c356f2dc5fc39b22c41df97485b21fdfd9239f9c6b**；**10/10 播放、9/9 窗口探针合格**，360 个资源点无缺失、ac/nominal、监控错误为空。首末资源点跨度 **124.341798 秒**，命令耗时 **150.549099 秒**。设备为 M1 / MacBookPro17,1 / macOS 27.0 (26A428)，arm64 profile、managedFallback/hardware。新增真实空树回归后完整 **86 项 Python 测试通过**。

三个窗口在干预后的 Profiler 回读均为 false；原始 `getFlagList` 同时显示 `timeline_recorder=ring`、`timeline_streams=Dart,Embedder,GC,Microtask`。关闭采样 Profiler 没有关闭 Timeline 记录。以下为 heap 的精确类型行，不把调用树祖先和子节点相加：

| 类型或分配来源 | live 1 数量 / B | disposed 2 数量 / B | disposed 8 数量 / B |
|---|---:|---:|---:|
| 全部 heap | 80,230 / 14,572,137 | 84,688 / 11,658,793 | 91,894 / 11,653,225 |
| TimelineEventArguments::CopyArgument | 889 / 14,832 | 4,538 / 73,936 | 5,918 / 97,808 |
| malloc in Dart_RecordTimelineEvent | 560 / 8,960 | 2,966 / 47,456 | 3,841 / 61,456 |
| AddAsyncTrackMetadataBasedOnEvent | 282 / 4,512 | 1,483 / 23,728 | 4,469 / 71,504 |
| malloc in SimpleHashMap::Lookup | 1 / 12,288 | 2 / 49,920 | 2 / 197,376 |
| FlutterEngineHandlerInfo | 26 / 832 | 9 / 288 | 9 / 288 |

完整反向调用树可沿 `Dart_RecordTimelineEvent → fml::tracing → flutter::VsyncWaiter::FireCallback → EmbedderTaskRunner` 回溯调用者，直接识别出 Flutter Vsync 相关 Timeline 事件分配。另一条路径由 `SimpleHashMap::Lookup` 回溯到 `TimelineEventRecorderWithPerfettoSupport::AddAsyncTrackMetadataBasedOnEvent → TimelineEventFixedBufferRecorder::CompleteEvent → TimelineEvent::Complete → Dart_RecordTimelineEvent → TraceEventAsyncBegin0`。disposed 2/8 该分支分别显示 48.0K / 192K（工具的舍入展示值），与 heap 中 hash map 类型总字节增加 **147,456 B** 相符，支持至少一个增长 hash map 属于 Timeline 异步轨道元数据记录路径。

因此本次已找到**部分剩余分配增长的具体记录来源**，下一步应隔离 Timeline 观察开销。不能把其他泛用 dart::malloc/calloc 行全部归入 Timeline，也不能把短程栈外推为此前百轮匿名增长的完整所有权证明。`ring` 模式并不证明这些元数据已经达到平台期或必然无限增长；本次没有地址连续性、释放历史或长程关闭 Timeline 对照，尚不裁定 VM 泄漏。

第 2→8 轮 heap 节点增加 7,206，但全部 heap 字节减少 5,568 B，说明增长行与下降行并存。普通 disposed 第 1→10 轮 RSS 减少 **11,796,480 B**、footprint 增加 **1,212,416 B**，端点跨度 98.021625 秒；不同工具时间、覆盖与 MSL 开销使它们不能组成对象所有权账本。三份全类别调用树根节点为 77,969 / 23.3M、82,844 / 14.3M、89,968 / 14.5M，既非纯 non-object 总量，也不与 heap 的时刻和口径相同。

### 归档与下一项

[完整证据](../../../tool/playback_benchmark/macos-allocation-stacks-observations.json)为 **61,979,497 B**，保留两次运行共 43 份原始文件及其哈希。最终三份调用树原文共约 570 MB，以 gzip+base64 无损保存，分别验证压缩内容和解压原文 SHA-256；没有截断为选中栈片段。归档还包含资源日志/JSONL/结果、heap、控制 RPC/journal、冻结根协议、应用及源码/依赖/制品/媒体指纹和可复查归档脚本。预备运行完整保留 `attributionComplete=false`，原始 `complete=true` 只表示旧规则下九个工具输出与窗口合格；最终 v2 拒绝空调用树，`attributionComplete=true` 仅表示本有界归因采集完成，不代表所有分配所有权已解决。

资源日志/JSONL/结果一致性、摘要重算、全部 RPC 回放与 journal 重组、两个运行的九个时钟窗口、heap 总和及源码身份均通过；最终 701 项源码指纹再次核验。此短程复用入口没有单独预写 `run/protocol.json`：预启动冻结的是根协议，资源模式元数据在结果中保留，归档明确记录该边界，不冒称两个预冻结协议。原文件另存忽略工作区 `allocation-stacks-preliminary/` 和 `allocation-stacks-final/`。

下一项：先验证受支持的 Timeline 查询/控制能力，固定独立启用与关闭（或空 streams）对照协议，再用实际状态回读评估相关分配；不修改 SDK，不增加强制 GC 或任意清空记录来制造内存下降。生产播放器本次未改。完整 P08 Task1/2、正式呈现/性能基线、连续长片、后台/多播放器/低内存、物理音画、跨设备/最低系统与 DRM 授权验收仍开放，`leakVerdict=null`、`performanceBaseline=false`、`budgetAdmission=false`。

独立最终复审通过：43 份原始文件及压缩/原文哈希、两组各 701 项源码指纹、18 个窗口资格、26 个 RPC 响应与 journal 重组、六份 heap、资源摘要及最终应用身份均核验一致。完整树支持上述 Timeline/Vsync 与异步元数据来源，预备失败未计为归因通过；Critical / Important / Minor 均无遗留。本有界切片可提交，全部匿名分配所有权、VM/全局泄漏、长期平台期、性能提升及完整 P08 仍未裁定。

## 2026-10-08：Timeline 记录开销独立对照

依据上一项已定位的 Timeline/Vsync 与异步轨道元数据分配，验证本地 vm_service 15.1.0 与[官方 API](https://pub.dev/documentation/vm_service/latest/vm_service/VmService/setVMTimelineFlags.html)：`setVMTimelineFlags` 的 recordedStreams 指定启用集合，未列出的流关闭；`getVMTimelineFlags` 回读 recorder、可用和实际记录流。工具仅允许既有 Dart/Embedder/GC/Microtask 或空列表，必须读取实际结果，拒绝无 recorder、未知流、状态不符与进程/group 变化；不调用 clearVMTimeline。

预先冻结启用→关闭两组，各独立 profile 十轮，均以相同 MSL full/NoCompact 启动，live 1 加载后将采样 Profiler 设为 false 并设定 Timeline 流，disposed 2/8 只读状态。三个 20 秒窗口依次控制/回读、完整 heap 类型表、详细 vmmap，每个进程上限 10 秒；每组九个计划探针缺失/失败均保留。此前已具备完整调用树所有权路径，本次不重复大体积全树采集。根对照协议与每组协议在各自启动前保存；短资源入口元数据位于结果中。

新增五项回归先因缺少控制/模式失败，初次 HTTP 测试只验证了 JSON 编码，完整 **92 项 Python 测试通过**，但随后实际 VM 拒绝了带引号的枚举列表；该测试不足以证明 VM 协议兼容。对照不清空已有事件、不强制 GC、不修改生产播放器、Dart、生成代码或 SDK；固定顺序、缓存未受控及 MSL 开销限制了性能与长期推论。

预备运行启用组 `macos-resource-20261008T014213Z`（PID 36824）十轮播放通过，但控制请求收到 -32602 invalid params，九个探针中零个合格；关闭组的空列表成功，九个合格，但整组比较不准入。所有原始失败响应、journal、资源记录与运行源码身份保留。根因经[本机 Dart revision 对应官方源码](https://github.com/dart-lang/sdk/blob/98116461144f4429ab873f8497023a5ec3b08127/runtime/vm/service.cc#L210)确认：HTTP 路径的 EnumListParameter 接收 `[Dart,Embedder,GC,Microtask]`，不是带引号的 JSON 字符串数组。新增正确传输期望先观察 RED，再作方法专用编码修正；实际状态仍须回读验证，不依赖传输单测自行推定成功。v2 协议明确该编码，重新运行完整独立对照。

### 正式对照结果

最终启用组 `macos-resource-20261008T014814Z` / PID **38174**，关闭组 `macos-resource-20261008T015046Z` / PID **38696**；两组均 **10/10 播放、9/9 窗口探针合格**，监控错误为空。共同 sourceHash **af5081a98b0da0ea981c04b5e8e707a96d6d6369bca33dcad91ba96b18b5a955**、704 项源码指纹；依赖/原生制品/媒体、设备和资源协议一致。M1 / MacBookPro17,1 / macOS 27.0 (26A428)、arm64 profile、managedFallback/hardware。启用/关闭分别 382 / 381 个资源点，全可用，实际均 ac/nominal；资源跨度 **124.130260 / 124.041847 秒**，命令耗时 **151.644994 / 150.014782 秒**。

`matchedConditions` 自动检查声明条件、源码和初始 Timeline 状态；实际电源/热状态另从所有资源点核验，不误称该字段包含所有环境控制。每组 VM 的 PID 与应用/系统 group 在三个窗口一致，干预后所有 Profiler 回读为 false。Timeline recorder 均为 Ring；启用组三窗实际 recordedStreams 均为四类，关闭组三窗均为空。两组干预前均为原有四类流，未声称从进程启动即关闭，也未调用清空接口。

| 分配类型 | 启用 disposed 2 数量 / B | 启用 disposed 8 数量 / B | 关闭 disposed 2 数量 / B | 关闭 disposed 8 数量 / B |
|---|---:|---:|---:|---:|
| TimelineEventArguments::CopyArgument | 5,513 / 89,536 | 5,939 / 98,144 | 820 / 13,728 | 820 / 13,728 |
| malloc in Dart_RecordTimelineEvent | 3,616 / 57,856 | 3,859 / 61,744 | 514 / 8,224 | 514 / 8,224 |
| AddAsyncTrackMetadataBasedOnEvent | 1,808 / 28,928 | 5,062 / 80,992 | 259 / 4,144 | 259 / 4,144 |
| malloc in SimpleHashMap::Lookup | 2 / 99,072 | 2 / 197,376 | 2 / 13,056 | 2 / 13,056 |
| FlutterEngineHandlerInfo | 9 / 288 | 9 / 288 | 9 / 288 | 9 / 288 |
| 全部 heap | 87,308 / 11,901,593 | 92,219 / 11,725,065 | 74,015 / 11,558,393 | 74,159 / 11,220,409 |

关闭组前三类在 live 1 也分别为 820/13,728、514/8,224、259/4,144，保持至第八轮；保留的初始分配没有被强制清空。结合上一项完整栈来源和本次受控流切换，支持 **Timeline 记录贡献了这些分配类型的持续增长**。启用组异步元数据增加 3,254 个 / 52,064 B、hash map 类型增加 98,304 B，而关闭组对应行不变；并不证明每个泛用 hash map 的具体所有权，也不把两次运行的绝对值相减当作回收字节或性能提升比例。

其他指标仍不能裁定完全稳定：关闭组第 2→8 轮总 heap 节点增加 144、字节减少 337,984 B，Malloc Small 脏页 16.3M→16.4M。启用组总 heap 节点增加 4,911、字节减少 176,528 B，Malloc Small 16.7M→16.8M。普通 disposed 第 1→10 轮启用组 RSS/footprint 增加 **3,702,784 / 3,063,808 B**，关闭组增加 **2,260,992 / 1,753,088 B**，端点跨度分别 97.778321 / 97.703888 秒；MSL、缓存、首次加载和分配器行为仍影响这些数值。没有全局无泄漏、长期平台期或生产性能优化结论。

### 证据、裁定与后续

[完整对照证据](../../../tool/playback_benchmark/macos-timeline-control-observations.json)为 **52,077,814 B**，保留预备和正式四次运行的 84 份原始文件、103 个 RPC 响应及 10 份 journal、九份完整 heap/详细 vmmap、所有协议/资源记录、四个实际应用可执行文件与源码/依赖/制品/媒体指纹、官方 SDK revision 源码片段和五份测试日志。预备启用组失败、关闭组单独通过均保留，整个预备比较仍为 false；36 个计划探针中 27 个合格、1 个实际控制失败、8 个未观测，未缩小分母。

归档再次核对所有身份/原始哈希、资源日志/JSONL/结果一致性、摘要重算、RPC 顺序回放与 journal 内容重组、可观测探针时间窗口、heap 类型总和与 vmmap 解析，正式两组条件和实际 ac/nominal 一致。完整原文件另存忽略工作区 `timeline-preliminary/` 和 `timeline-final/`。方法修正后的完整 **92 项 Python 测试通过**，独立复审结论另附。

下一项为**Profiler 与 Timeline 均关闭后的百轮资源/生命周期复核**：预先固定无 MSL 的长程协议，继续回读实际状态，再判断剩余增长。关闭 Timeline 是诊断条件调整，不是本插件生产修复；本项没有生产或 SDK 改动。连续长片、后台/多播放器/低内存、物理音画、跨设备/最低系统、DRM 授权验收、正式呈现/性能基线和完整 P08 Task1/2 保持开放。

独立最终复审通过：84 份原始文件、四组各 704 项源码指纹、全部依赖/制品/媒体/应用身份、103 个 RPC 与 10 份 journal、九份 heap/vmmap、36 个计划探针及所有资源摘要均一致，报告数字核验通过；Critical / Important / Minor 均无遗留。本 Timeline-control 切片可提交，上述所有权/泄漏/长期稳定性和完整 P08 边界不变。

## 2026-10-08：Profiler 与 Timeline 双关闭百轮复核

上一项独立短程对照已证明 Timeline 记录贡献特定分配类型增长。本项固定独立长程复核：100 轮 profile 创建/播放/释放，不启用 MSL，资源观察至少 600 秒；live 1、disposed 10/50/100 四个 30 秒窗口，依次采集 Profiler/Timeline 控制及回读、`heap --noContent`、详细 vmmap、应用/系统 isolate group 内存。根协议及资源协议均在测量进程启动前保存，16 个计划探针缺失/失败均保留。

live 1 首次加载后将 Profiler 设为 false、Timeline recordedStreams 设为空；其余窗口只读实际状态。复用上一项已实测的受支持接口和 HTTP 枚举编码，继续要求精确 PID/group 身份与原生时钟窗口；单探针进程上限 10 秒、RPC 单次读取上限 2 秒、测试/命令分别上限 900/1200 秒。拒绝继承 MallocStackLogging 环境，无 clearVMTimeline、强制 GC、Dart、生成代码、生产播放器或 SDK 改动。

四项新增回归先因缺少长程入口/模式失败，再验证：失败仍保留 16 探针、四个窗口先回读状态再采内存、实际仍有启用流时不继续采 heap 或准入、长短/混合模式拒绝。完整 **96 项 Python 测试通过**。本项是负载释放耐久诊断，不是连续长片、从启动即关闭、与旧百轮的严格匹配对照或正式性能基线。

### 百轮结果与剩余变化

运行 `macos-resource-20261008T023956Z` / PID **39745**，sourceHash **d3da67a03016cb4dcc6aea3484551f7e3b7057319359f1d39d83d1e77abcb2f1**、705 项源码指纹。**100/100 播放、16/16 窗口探针合格**，监控错误为空；3220 个资源点全可用、ac/nominal，首末跨度 **732.713140 秒**，命令耗时 **790.788545 秒**。本机 M1 / MacBookPro17,1 / macOS 27.0 (26A428)、arm64 profile、managedFallback/hardware；≥600 秒准入通过。最终第 100 轮探针窗口位于普通资源序列之后，不能把采样跨度解释为连续长片时长。

live 1 干预后的 Profiler 回读为 false，随后第 10/50/100 轮前后回读均为 false；四窗 Timeline recordedStreams 均为空、recorder 为 Ring。控制和内存采集的 PID、应用/系统 group 身份一致。没有启用 MSL，本轮不能再以分配栈派生名称逐项追踪 Timeline 类型；对应来源证据仍来自上一项短程对照。

| 窗口 | 全部 heap 节点 / B | non-object 节点 / B | Malloc Small 脏页 | Untagged 脏页 | vmmap footprint |
|---|---:|---:|---:|---:|---:|
| 1 live | 83,720 / 15,276,233 | 32,548 / 8,990,385 | 16.8M | 16.9M | 62.6M |
| 10 disposed | 77,432 / 11,755,257 | 30,874 / 5,856,929 | 16.9M | 17.6M | 53.8M |
| 50 disposed | 77,557 / 11,612,137 | 31,002 / 5,712,417 | 17.5M | 17.5M | 54.3M |
| 100 disposed | 77,728 / 11,651,177 | 31,174 / 5,750,705 | 17.5M | 19.2M | 56.1M |

第 50→100 轮 non-object 仍增加 **172 个 / 38,288 B**，全部 heap 增加 171 个 / 39,040 B；Malloc Small 脏页展示值不变，Untagged 与 footprint 仍增加。本轮不再出现此前百轮数万节点的增长形态，但方法/运行条件不同，不据两个独立百轮结果计算优化百分比，也不能据更小的残余宣布达到稳定平台或全部归因。

八个核心 Host/协调器/会话/媒体/解码/调度/呈现/账本类型在 live 各一个，账本 Token 为 189；第 10/50/100 轮释放后均未列出，继续记录 `not_listed` / null，不解释为证明全部释放。registry 四窗均一个。FlutterEngineHandlerInfo 为 **26 → 9 / 9 / 9**，Swift.StringStorage 为 **152 → 130 / 130 / 130**，未重现已修复的每轮通道记录保留。

本次 19,693,568 B Untagged 区间为 `0x11dc00000..0x11eec8000`（末地址不含），四次脏页均 **192K**。这只是同进程四次映射观察；没有 MSL 地址历史，不冒充该地址在整个运行中的分配连续性/释放证明，亦不外推过去进程的地址所有权。

| 窗口 | 应用 group heapUsage / B | 系统 group heapUsage / B |
|---|---:|---:|
| 1 live | 8,320,560 | 8,105,776 |
| 10 disposed | 8,783,424 | 8,421,360 |
| 50 disposed | 7,334,880 | 8,037,088 |
| 100 disposed | 9,236,704 | 8,932,048 |

Dart 用量先下降后上升，容量和 externalUsage 精确值全部保留。不同采集时刻和统计范围使其不能与 vmmap/RSS 相减建立内存所有权账本；没有主动 GC，也不凭四个快照推断 GC 周期或泄漏。

普通 disposed 第 1→100 轮 RSS **148,881,408 → 144,441,344 B**、footprint **64,930,800 → 58,016,752 B**，差值 **−4,440,064 / −6,914,048 B**，跨度 696.439025 秒。但第 50→100 轮二者均增加 **1,851,392 B**，因此首末回落不能证明后半程稳定或整体无泄漏。

### 归档、裁定与下一项

[完整百轮证据](../../../tool/playback_benchmark/macos-timeline-off-long-observations.json)为 **15,384,309 B**，包括 34 份原始文件、58 个 RPC 响应与八份 journal、四份完整 heap/详细 vmmap、全部资源日志/JSONL/结果、两个预冻结协议、源码/依赖/制品/媒体/采样器/应用身份、三份测试日志与归档校验脚本。资源摘要与耐久/释放端点重算、RPC 顺序回放和 journal 重组、16 个窗口、heap 类型总和、vmmap 解析及全部身份再次核验通过；原文件另存忽略工作区 `timeline-long-final/`。

裁定：**本百轮双关闭复核完成**，确认所测释放检查点的核心对象记录和已修复通道行为，保留残余匿名分配及后半程资源变化；没有预算阈值依据将其判为“可接受增长”，也没有全局无泄漏或正式基线结论。下一项转向**连续长片播放的冻结协议与验证**，将残余变化保留为后续观察项；创建/释放百轮不能替代单会话持续播放，不再用重复细分同一短负载充当长播覆盖。

后台/多播放器/低内存、物理音画、跨设备/最低系统、DRM 授权验收、正式呈现/性能基线和完整 P08 Task1/2 仍开放。生产播放器及 SDK 未改；`leakVerdict=null`、`performanceBaseline=false`、`budgetAdmission=false`。

独立最终复审通过：34 份原始文件、705 项源码及全部依赖/媒体/制品/采样器/应用身份、两个冻结协议、58 次 RPC 与八份 journal、16 个窗口、四份 heap/vmmap、全部资源摘要和报告数字均一致。Critical / Important / Minor 均无遗留，本百轮诊断切片可提交；连续长片及上述所有权/泄漏/基线/完整 P08 边界不变。
