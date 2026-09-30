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
