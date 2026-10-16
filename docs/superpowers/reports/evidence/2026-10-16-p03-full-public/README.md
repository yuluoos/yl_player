# P03 公开 Flutter 完整格式同次音画验收（2026-10-16）

本轮接入固定完整目录的公开 controller/session/view 验收，并修复实跑暴露的取消与采集时序问题。**完整 P03 / CAP-FORMAT 仍未通过**；失败的必需项保留在分母内。当前证据只适用于这里冻结的 clear Debug 产品、宿主和受控采集协议。

## 最终实跑

22 个输入分别经本地文件和显式 managed HTTP 加载：40 个必需单元、2 个 MPEG-2 诊断单元、2 个损坏输入。产品正常选择解码路线；无强制 decoder、软解准入或放宽容差。每个单元是独立 run/session，全部绑定同一平台的单次构建身份；不同构建/轮次的通过项不拼接。

| 平台 | 已执行 | 必需项通过 | 产品 SHA-256 |
| --- | ---: | ---: | --- |
| Android | 44/44 | 36/40 | `10816201a8dfecf9ea7ed2503d97dce1378cca2e799475d5875e28c64d1bd0b5` |
| macOS | 44/44 | 32/40 | `65ca5dc8ac139f5406776d405403ae46c8a4bfb417109eeff56fd2056dfb5411` |
| iOS Simulator | 44/44 | 0/40 | `4f1b77d0946d79a33cc0168d1b643ee3789caaf996f162a086cd177b463534a0` |

最终目录为 `android-matrix-complete`、`macos-matrix-final`、`ios-matrix-final`。各目录的 `matrix-plan.json`、`records.json.gz` 和 `matrix-result.json` 保存完整计划、原始数据和独立重放结果；子目录保留提取原文、框架状态、日志与逐阶段 PCM/像素。`formatScopeAcceptance` 仅在固定40项全部通过时为真，`fullAcceptance` 始终为假。

Android 剩余 AV1/Main10 文件与 HTTP 路径受当前设备解码能力/准入限制。Apple 的实际设备解码、managed 路径与 AVPlayer 消费采集缺口以最终逐行失败为准，不能把完成加载、框架状态或单独主机解码当作音画通过。`remaining-required.json` 汇总所有仍失败的必需单元。

## 本轮修复与验证

- 完整目录聚合重新验证原始音画、单次产品/媒体/run/session/transport 身份、框架最终结果和制品稳定性。子进程退出失败或采集错误不能通过；Android 重新解析原始 JSONL，尾部损坏不能被有效前缀掩盖。进度文件明确 provisional，最终仍完整独立重放。
- owned HTTP Range 服务提供不可变样本，要求本次 run header；原生独立检查实际 locator、managed policy、header 与样本哈希。该服务器不承担弱网或 ABR 模拟。
- 保留真实 mono PCM 与实际输出声道；不伪造 PCM 或用计划声道覆盖实际输出。Android 仅对声明为 mono 的源接受真实 mono/双声道复制，并逐声道测量。
- Apple 网络 seek 从立即断言 reset 改为等待实际音频重置。所有平台还要求当前截图配对的实际消费位置到达阶段目标，避免 seek 后陈旧公开 position 提前终止采集。
- Android HTTP fallback dispose 的 `NetworkOnMainThreadException` 已定位到 caller 上关闭响应体：cancel 只通知/中断调用，响应体由 demux worker 关闭；引用先清空，客户端在 finally 中释放。真实 FLV/TS/AVI/EAC3/DTS/AC3/PS HTTP 行验证释放恢复。
- 清理逐个释放 player、view、HTTP server、临时文件；之前的播放错误不会被后续清理异常替换。补充 networkPolicy、取消线程与采集接口注释。

Python58/58、Flutter example96/96（并行P06提交后的当前树；本轮此前83/83）、7文件静态分析、公开 API 检查通过。Android JVM543项零失败（3项既有跳过，540通过），原生观察测试3/3通过；受影响 macOS 原生44/44、零跳过。三端最终采集包均构建成功。macOS/Android 普通 Debug 与 Release 验收桥隔离检查保留制品哈希与符号/类扫描；不冒充 release 运行验收。

Android/macOS 同一最终制品的框架末尾负例：六行原始音画通过后仍拒绝总体通过；错误构建身份负例在三端均在播放前拒绝。iOS 没有六行正向原始音画，不宣称完成该平台框架末尾负例。

## 历史、复核与裁定

历史目录完整保留：macOS 首轮18/40、Android首轮29/40是旧汇总；`android-release-diagnostic` 记录真实取消异常；`android-matrix-final` 是取消修复后、消费位置修复前的34/40。它们不是本轮最终证明，也不能用旧缓存结果替换新门禁。错误 JDK22 的 JVM失败、错误测试注解/命令调用、所有 RED 和修复后 GREEN 均保留；最终 Android 用项目所需 JDK17。

一次独立只读复核见 [final-review.md](final-review.md)，Important 子进程失败传播和 Minor 清理均已修复，没有延期 Minor。实跑新增根因与后续自行验证在 [progress.md](progress.md)；独立复核不冒充覆盖后来才发现的所有运行时根因。

裁定及错误选择的代价：独立子会话绑定一个产品以防跨会话拼接；只把真实消费位置作为采集完成证据以防陈旧 UI 状态伪证；HTTP cancel 不执行响应体网络读以防 UI 异常和资源滞留；进度计数不可作为最终准入以防缓存通过掩盖失败；Apple 明确拒绝的严格 progressive 路由不能只删除策略门禁，否则会虚报 managed、预算或硬件保证。复核未裁定的边界、独立参考、真实扬声器/屏幕、release、最低 OS/Intel、持续热资格和未知设备软件准入继续开放；擅自从短 Debug 标记窗口推导这些能力会造成错误发布结论。Task7/8复合项保持开放。另一会话的 P05/P06 commits 与长播放/弱网ABR范围不包含在本次改动中。

## 重放与完整性

从仓库根目录执行：

```sh
python3 -B docs/superpowers/reports/evidence/2026-10-16-p03-full-public/replay.py
```

重放重新计算三端最终原始门禁、检查负例，并核对 `manifest.json` 的全部归档 SHA-256。`source-provenance-complete.json` 绑定最终源码；每个最终 matrix plan 绑定实际安装/加载产品。构建包留在本机 scratch，不把二进制构建产物加入仓库。原始捕获不证明物理屏幕色准、连续无干预显示、受保护读回或持续负载。
