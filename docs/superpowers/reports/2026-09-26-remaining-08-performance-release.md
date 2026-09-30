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
