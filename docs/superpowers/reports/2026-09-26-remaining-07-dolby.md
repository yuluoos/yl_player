# P07 执行报告：Task1 参考、候选与完整性门槛

更新于2026-09-29；最初基线 `e69d5dc47db3dc08a808dd73c80de56acd446a4d`，各增量基线分别记录。**Task1 部分完成：基线、调查台账、三端arm64候选构建与本机有限GPU实验已交付；原始FEL、独立参考、最终容差及完整映射验证尚缺。CAP-DV-MAP / CAP-DV-OUT 均未完成。** 以下Task1A为历史记录，最新进度见末尾Task1B2。本轮没有修改生产播放器、放宽元数据拒绝或新增依赖。

## 现有基线与真实运行

当前主机macOS27.0(26A428)/arm64，Xcode27.0(27A266a)，三个Apple SDK均27.0；包部署下限保持Android24/iOS15/macOS12。当前运行不是iOS物理设备或Android证据。

| 命令 | 实际结果 | 能证明的范围 |
|---|---|---|
| `sh tool/apple_fel/run_tests.sh` | 退出0，1个检查程序通过 | 配对重排、重复、缺帧、旧代际、未知PTS及容量 |
| `bash tool/apple_hdr/run_fel_compositor_tests.sh` | 退出0，1个检查程序通过 | 合成输入的metadata拒绝、正负/零残差、MMR、EL插值、Half输出与scalar对照、原生layer接收 |
| `sh tool/apple_hdr/run_tests.sh` | 退出0，4个检查程序通过 | HDR精度策略、mailbox、sample/RPU保留、lease/首帧/释放 |
| `python3 -B -m unittest discover -s tool/dolby_reference -p 'test_*.py'` | 8项通过 | 调查覆盖、状态不可误提升、缺项/来源替换拒绝、哈希及路径边界 |
| `python3 -B tool/dolby_reference/inventory.py --check-snapshot` | 退出0，24行/72个平台行，源码哈希匹配；Task1=incomplete | 台账与冻结源码有效，不是播放验收 |

原始日志位于 `.superpowers/sdd/2026-09-26-remaining-07-dolby/` 的 `pairing.log`、`compositor.log`、`hdr.log`、`inventory-red.log`、`inventory-green.log`。8项工具测试在实现前因模块缺失失败，随后通过。原生脚本输出中有既有API弃用/变量警告，无新增失败或skip。6是独立检查可执行程序数，不能写成完整XCTest数量；本次没有执行完整原生或Dart套件。

[baseline.json](../../../tool/dolby_reference/baseline.json) 冻结生产FEL/HDR、FFmpeg桥接与版本锁、Android核心及配置、现有检查与合成夹具源码SHA-256。旧报告中 `/private/tmp/yl-fel-upstream` 和相关原始FEL临时文件目前不可用；原始样本哈希保留null。未搜索或读取其他无关用户媒体。既有删去display extensions的衍生夹具不视为原始参考。

既有算术容差只用于合成小图选定像素的线性BT.2020 RGB/Half回读；不是完整画质阈值。原始用户FEL曾含非单位NLQ最大值、L2/L4，现有实现仍明确拒绝，历史发现不能替代本次对缺失媒体的重验。

## 固定候选与具体缺口

[candidates.json](../../../tool/dolby_reference/candidates.json) 固定版本、提交、14个已读取上游源文件SHA-256及本机依赖预检。没有从浮动main定义ABI，后续必须沿固定revision复现。

| 路线 | 已核查 | 不能据此成立的结论 / 下一实验 |
|---|---|---|
| 当前Apple FEL | FFmpeg9.0.1桥接、双VideoToolbox、Metal RGBAHalf；metadata仅接受L1/L5/L6且NLQ最大值限1 | 未执行完整显示管理。恢复原始含trims/非单位NLQ流与独立目标图，再逐阶段扩展 |
| libplacebo **7.372.0**, `c42968d8616a1d1c8ad5f4f1a8d6f5a9cb396e56` | 固定代码含BL reshape、多项式/MMR、LINEAR_DZ NLQ与EL绑定；公开metadata入口提取源亮度和L1 | 已检查入口未展示L2/L4/L8目标显示处理；内部NLQ表示也没有承载独立vdr_in_max字段。不能宣称完整CM或本源非单位NLQ正确；需独立向量及trim参考验证 |
| libdovi **3.4.0** / dovi_tool **2.3.4**, `614c816b6446dcd1dbaf433403d499a6026fbb5a` | metadata解析/写入；README列出CM2.9/4.0 XML→RPU的多个level | 元数据工具不等于屏幕映射器；可辅助盘点，不能拿转换后的P8.1替代原始FEL |
| Apple系统 | SDK27；官方文档说明P8.4的系统渲染，2026 HLS更新新增iOS/macOS等平台P8.1支持 | 不证明最低系统、P7 FEL、全部CM或外接链路；需按OS/原始样本逐项实际验收 |
| Android系统 / Media3 **1.11.0** | 仓库固定依赖；官方HDR文档要求设备能力与输出面配合 | OEM/decoder/display条件不同，不能从库版本或DV标签推断Profile7完整映射；需实际codec/profile及输出证据 |
| 既有FFmpeg **9.0.1** | 保留签名源pin与五slice artifact lock，桥接拆BL/EL和解析RPU | 解析不等于显示映射；本次未重新构建五slice，不重复宣称构建验收 |

libplacebo依据：[版本/构建](https://github.com/haasn/libplacebo/blob/c42968d8616a1d1c8ad5f4f1a8d6f5a9cb396e56/meson.build)、[metadata入口](https://github.com/haasn/libplacebo/blob/c42968d8616a1d1c8ad5f4f1a8d6f5a9cb396e56/src/include/libplacebo/utils/libav_internal.h#L941)、[NLQ表示](https://github.com/haasn/libplacebo/blob/c42968d8616a1d1c8ad5f4f1a8d6f5a9cb396e56/src/include/libplacebo/colorspace.h#L150)、[shader](https://github.com/haasn/libplacebo/blob/c42968d8616a1d1c8ad5f4f1a8d6f5a9cb396e56/src/shaders/colorspace.c#L106)。这些是源码调查，未作为独立画质参考。

libdovi依据：[库版本/MSRV](https://github.com/quietvoid/dovi_tool/blob/614c816b6446dcd1dbaf433403d499a6026fbb5a/dolby_vision/Cargo.toml)、[CLI版本/MSRV](https://github.com/quietvoid/dovi_tool/blob/614c816b6446dcd1dbaf433403d499a6026fbb5a/Cargo.toml)、[元数据用途](https://github.com/quietvoid/dovi_tool/blob/614c816b6446dcd1dbaf433403d499a6026fbb5a/README.md)。

系统依据：[Apple P8.4](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)、[Apple 2026 HLS第4页](https://developer.apple.com/streaming/Whats-new-HLS.pdf)、[Apple环境元数据](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata)、[Android HDR播放](https://developer.android.com/media/grow/hdr-playback)。源和目标环境/信号元数据都需保留，系统能播放不能替代独立画面对照。

## 三端构建与依赖实况

新候选均**未构建/未接入三平台**。本次只完成版本和本机前置条件调查，不写成构建通过，也不声称平台不可实现。

- libplacebo声明LGPL2.1+，Meson≥1.3、C11/C++20；可用后端调查为Vulkan/OpenGL/D3D11，当前选定源码没有直接Metal选项。Apple需验证具体后端及像素/同步桥接，Android需验证GPU/导入/输出条件。源码float参数不保证所有阶段或输出格式精度。
- 当前PATH没有meson/ninja；pkg-config未发现vulkan/glslang/shaderc/libdovi/libplacebo，lcms2为2.19。尚未补齐构建图及验证交叉编译，不自动安装这些库或替换现有生产路径。
- libdovi声明MIT、库Rust最低1.88；同提交CLI最低1.95，当前Rust1.94不能满足该CLI声明。库本身MSRV满足不代表目标构建通过。
- 不为“获得绿色构建”削弱FEL、改用BL或关闭需要验证的处理；补齐构建只能作为下一独立实验，不能解除参考门槛。

## 样本、覆盖与参考门槛

找到 [Dolby官方测试内容仓库](https://github.com/DolbyLaboratories/dolby-vision-contents)，包含P5/P8.1/P8.4各1080p和2160p，共6个线索。固定提交和LFS声明哈希在 [sample-candidates.json](../../../tool/dolby_reference/sample-candidates.json)。当前仅读取LFS指针，未下载媒体、未核实内容使用条款、CM/levels或实际媒体hash；不能将其写成已经取得的授权输入。仓库清单没有P7 FEL独立目标显示图。这里不推断网络上不存在可用参考，只记录本次尚未取得。

[cases.json](../../../tool/dolby_reference/cases.json) 为6个Profile类别×4个CM/level调查条件，24行、每行Android/iOS/macOS状态独立。组合适用性均to_verify，原始输入和参考hash均null，算术not_run、画质与信号external_missing。现有合成算术通过只记在baseline，不迁移到任一真实Profile行。该网格不是元数据全集；真实样本出现其他合法level时须扩展调查。

[映射契约](../specs/2026-09-26-dolby-mapping-contract.md) 已定义来源/显示参数、精确帧对齐、比较域、全帧/active area/边界、误差指标与预先冻结规则；独立参考、目标参数和数值容差尚缺，最后一个完整性门槛未通过。未开始扩大compositor适用范围，也不把任一候选标记为完整目标可行。

## 余项与决定

Task1尚需：原始合法FEL及其hash、独立多帧目标输出和来源/参数、候选实际三端构建与精度实验、逐组合有效性确认、冻结最终误差容差。Task2/3依赖参考的映射实现暂不能开始；Task4物理DV链路也缺失。现有实现和部署下限保持不变。

本次决定：先交付可核查的基线/调查台账，保留缺项；其代价是本增量不增加完整杜比播放范围。拒绝用合成fixture、LFS声明或单层演示片替代独立完整参考，防止后续把部分算术/标签当作完整质量。

## 本增量关键文件SHA-256

- `tool/dolby_reference/inventory.py`：`f2efd8d51ce02d458d5ba2e1e41b0de8c81cac19fc0539cf19a061a88b9f71d5`
- `tool/dolby_reference/test_inventory.py`：`18806dfe7f12cf5d229826b723600af4cff2ec9db9946d14b447b0f0a73951f2`
- `tool/dolby_reference/cases.json`：`9d97716e851bccf1404e767ba67e087fa47d100997f132a4975e23ae69c45d20`
- `tool/dolby_reference/baseline.json`：`8f3fa5396d9980a806ee601c11e9145b5d830ac65a924b90ba2bffc86bfdaf77`
- `tool/dolby_reference/candidates.json`：`ae15d97a4e9ecfe2734196fe8ae8084a548a3b82e3f0736601af4510f44e6d18`
- `tool/dolby_reference/sample-candidates.json`：`75959c43cf9995a14dbfbe127bd5a996b0676c93236020b1f94d2750ec976938`
- `docs/superpowers/specs/2026-09-26-dolby-mapping-contract.md`：`c324c7f2400a9d631523295f62faa37ec1bbc685a243cc121a3f82ff3d6a9908`

独立fresh review完成：未发现重要问题；核对25个基线源码hash与e69d5dc一致，14个固定上游源码hash、版本/MSRV/日志和状态边界一致。仅覆盖Task1A，不代替候选构建、完整画质或物理输出验收。最终工具8项通过，snapshot匹配；没有再次派发复审。

## 2026-09-28 Task1B1：实际候选构建与第一份官方输入

基线 `798fc80`，延续同一干净分支。本次补齐两个候选的Android/iOS/macOS **arm64构建**，没有接入生产。上方Task1A未构建/未下载描述是历史状态；当前以本节、[build-evidence.json](../../../tool/dolby_reference/build-evidence.json) 和 [sample-observation.json](../../../tool/dolby_reference/sample-observation.json) 为准。Task1仍缺原始P7 FEL、独立目标显示参考/容差和实际GPU/物理输出。

| 项目 | 最终实际结果 | 限制 |
|---|---|---|
| libdovi3.4.0 | 官方Rust1.94三端arm64静态库构建成功；三端C API消费者链接成功 | iOS/Android未运行；不是映射器 |
| libdovi macOS | 上游2单测通过；C ABI探针5个退出预期匹配，含真实首RPU成功及无效/缺项输入拒绝 | 单测最初使用Homebrew Rust；最终静态库/C ABI用官方工具链 |
| libplacebo7.372.0 | OpenGL+Dovi路线三端arm64动态库构建成功 | Vulkan/直接Metal及联合libdovi未验证；未接平台视图 |
| libplacebo macOS | 13通过、1跳过、0失败；opengl_surfaceless.c退出77 | GPU渲染测试未执行，不能计作14通过 |
| 调查/证据测试 | 最终12项通过；新增4项中3项先因证据文件缺失失败 | 只保证台账边界，不替代真实播放 |
| 官方P5 1080p输入 | 141,871,521字节，全文件SHA-256匹配发布方LFS声明 | 没有取得独立目标图；不是P7 FEL |
| 首RPU盘点 | 167字节；P5、CM2.9块，L1/L2/L4/L5/L6；PTS0/24000 | 只检查首RPU，不推断全片或CM4覆盖 |

实际Mach-O消费者下限为macOS12.0/iOS15.0，libplacebo动态库也分别为12.0/15.0；Android用NDK28.2.13676358的API24 wrapper，最终库和探针为aarch64 ELF。这里只证明目标编译/链接，没有在最低系统设备执行，不能宣称完整兼容性。未修改包最低系统或现有FEL/HDR实现。

### 版本、复现与失败保留

[探针说明](../../../tool/dolby_reference/probes/README.md)记录命令、工具、隔离sysroot、cross配置与边界。6个实际库hash、源码归档/子模块/官方Rust组件校验和和运行日志hash保存于build-evidence。所有二进制/媒体在忽略的 `build-probes/`，没有发布或进入播放器依赖。原始锁文件未改；使用`cargo --locked`。宿主ffprobe8.0.1仅做离线盘点，生产FFmpeg9.0.1不变。

首次失败均保留并按原因处理：源码归档不含glad/fast_float/Vulkan-Headers子模块，按原commit补齐；上游可选xxhash/头文件测试路径问题，关闭可选缓存哈希并显式提供已安装dav1d头；错误Meson reconfigure参数/属性段按工具错误修正。未修改上游源码、跳过断言或关闭Dovi处理。

Homebrew Rust1.94和官方std ABI不兼容；其自带macOS std还有26.0下限，未作为最终候选采用。改用校验过的官方编译器与三端std。强加主机最低系统变量曾导致Xcode27生成mis-aligned LINKEDIT的proc-macro，最终用新的隔离目录和官方默认host配置构建，再以macOS12消费者链接并核对产物，无高系统版本链接警告。初次将crate-type传到rustc而非cargo导致依赖格式报错，也已修正；未将这些失败描述成候选最终不支持。

### 样本来源与变化

[官方样本附带署名说明](https://github.com/DolbyLaboratories/dolby-vision-contents/blob/957c53ac160e11ae581aa1f4fe811a8ad6cf27df/SolLevante_Netflix/SolLevante%20by%20Netflix.docx)声明：SolLevante由Netflix, Inc.提供、Dolby, Inc.修改，按[CC BY4.0](https://creativecommons.org/licenses/by/4.0/)分发。本次保留署名，下载的MP4未修改；首access unit/RPU抽取是解析衍生物，不是改写元数据的替代片。声明文件hash已记录。其余5份官方样本仍未下载。

首RPU的L2 trim_slope=2070，不能以“有P5素材”推断所有动态映射已完成。当前24行历史调查网格保留原来的未验收状态，新样本仅补充输入观察。真正升级到支持/画质通过须取得同目标显示参数的独立多帧输出，冻结容差并证明实际处理；GPU skip、库可编译或可解析RPU都不解除这一门槛。

本次决定：只做固定候选编译与非保护公开输入盘点，生产依赖/渲染行为不改；其代价是仍没有新增完整杜比能力。移动端运行、其他架构、最低系统实机和实际GPU精度继续待验证，不从arm64构建外推。

### Task1B1 最终复审与文件校验

单次独立复审未发现重要问题；6个库与17份日志的哈希匹配，上游libdovi 211份、libplacebo 242份源码与归档一致。C ABI签名、错误路径和释放、官方输入及首RPU哈希已核对。复审实跑12项Python测试通过。GPU跳过和移动端未运行仍保留，Task1未勾选完成；没有再次派发复审。

以下哈希对应本次增量，上方Task1A哈希保留为历史记录：

- `tool/dolby_reference/build-evidence.json`：`9d7cef633a6d52b70a4c374970a77aafe8e0a335b35970e1d7fb3d75c2b5380c`
- `tool/dolby_reference/sample-observation.json`：`16115abd6b264369dbdc6cc5d455129d9aac051477ef955ef97ba1f0291866a0`
- `tool/dolby_reference/candidates.json`：`6f9af592228fb2da5c8465c0214da632565176775252b5c7564138d6bf90531f`
- `tool/dolby_reference/sample-candidates.json`：`12901caae3c466079815ae4bda22bfc76348775e9599ab401673a09ecd6721aa`
- `tool/dolby_reference/test_build_evidence.py`：`e9398248c4614d1d1e5c4e3a485c7e11b6bd5e49cafb7ab92e78bb4a186cd2fb`
- `tool/dolby_reference/probes/libdovi_smoke.c`：`01005a65be6d3bc30a89c61a7740d6d4e0cab28c30ef57918800df96e3f099e8`
- `tool/dolby_reference/probes/inspect_rpu.rs`：`88858633006b312a9208f3f100d63def0723e834c376ae7a61cb5d1c731aa1ce`
- `tool/dolby_reference/probes/README.md`：`a18ec7371b79dfbb8dcbb666d1022cb9b59b2b2e9fdf93ec20f322b2f542e80d`

## 2026-09-29 Task1B2：本机 GPU 实验与剩余外部条件

基线 `d46b1a0`。本增量完成macOS候选原生GPU子实验，**Task1B2与Task1整体仍未完成**。新增 [CGL实验记录](../../../tool/dolby_reference/runtime-evidence.json) 和 [复现入口](../../../tool/dolby_reference/probes/run_cgl_tests.sh)，生产源码、依赖、部署下限和历史验收状态不变。

- Apple M1/macOS27.0 (26A428)，CGL加速上下文；OpenGL4.1/GLSL410。固定libplacebo7.372.0的原始GPU测试在真实GPU运行并退出0。驱动字符串含Metal不等于直接Metal后端。
- 实际浮点shader目标为rgba32f、位对齐目标为rgba16。纹理读回、色彩/传递函数往返、缩放、渲染/帧队列与10-bit高低位对齐走到了上游断言。其容差是既有合成测试容差，未转用为最终杜比显示容差。
- Dolby段使用上游合成 `dovi_meta`，只验证reshape/decode shader能够dispatch；没有传入增强层，没有真实媒体解码或独立golden像素比较。不能从这里推出NLQ/FEL、L2/L8 trims或CM完整画质通过。
- 上游GPU入口带条件分支：compute_queues/max_ssbo_size均0，峰值检测及H.274报告能力不足；GL_KHR_debug缺失；planar、DMA-BUF和host-pointer路径未验证。进程退出0不等于所有功能通过；原13通过/1 EGL跳过记录保持原样。
- 首次沙箱上下文取得失败10017/退出77，主机权限运行成功；复现脚本缺构建目录返回2。新增测试进入既有unittest发现入口：默认12通过/1 GPU跳过，显式开启后13通过/0跳过。未修改上游测试断言；没有新增生产行为，使用实际研究探针及上游断言验证。

设备发现最初受沙箱影响（ADB监听被拒、devicectl超时），主机重试成功：ADB无设备；发现已配对iPhone16/iOS27，但tunnel unavailable、DDI不可用；另有3个模拟器，未作为实体设备证据。没有安装应用、重新配对或修改设备。可执行文件最低版本为macOS12，但实际仅在27运行；最低系统兼容性仍待验证。原始设备清单留在忽略目录，提交记录不含序列号/UDID。

### 原始输入与独立参考核查

本轮核查 [Kodi官方样本页](https://kodi.wiki/view/Samples) 的FEL测试链接；该页对非copyleft片段声明fair use，但本轮未核验这些媒体的原始字节、使用依据或独立目标输出，因此只保留为线索。[dovi_tool讨论168](https://github.com/quietvoid/dovi_tool/discussions/168) 涉及删除mapping的单层衍生物，维护者也指出所讨论pattern使用随机RPU；这类结果不作为原始FEL或独立显示参考。[Dolby Browser Test Kit入口](https://ott.dolby.com/browser_test_kit/help_files/index.html)检索到但本轮页面读取失败，不猜测其覆盖。以上是本轮检索结果，不宣称不存在可用公开参考。

仍缺：可核验的原始P7 FEL及使用依据、同目标显示参数的独立多帧输出/参考hash、事先冻结的最终容差、移动端真实运行和物理DV输出链路。已向用户询问是否有本地原始材料，同时完成了不依赖材料的GPU实验。缺参考时不进入Task2/3映射实现，也不拿合成fixture或上游往返结果冒充独立参考。

本次决定：在既有固定候选上补CGL运行证据，保留所有能力错误和跳过；代价是该结果只适用于当前Mac的有限路径，不能外推移动端或完整映射。研究目录继续保留，因为P07尚未完成。

本增量关键文件SHA-256：

- `tool/dolby_reference/runtime-evidence.json`：`527278f71b830a1530bc77330ddef0227903e8e56412a0f34f531a1a70ed45c2`
- `tool/dolby_reference/probes/placebo_cgl_tests.c`：`880230de1548b9acd44159f97632ad96af8fa9f92397243c595eeae2515d5095`
- `tool/dolby_reference/probes/run_cgl_tests.sh`：`89bc0956a2f3a674559c65a7e20b3a40c4a0dcfb25605d6cc9b4b76c958c50e4`
- `tool/dolby_reference/test_cgl_probe.py`：`622bffd28c33246a9b10b9143f6b971fc86adb37708f667851e8f2dcfb6d49d4`

单次独立复审未发现重要或次要问题：60项登记校验和匹配（含45个核心对象），242份上游源码与固定归档一致；复审默认发现12通过/1跳过，显式GPU运行依据原始13通过日志。复审没有重跑GPU或覆盖证据。未评判的完整FEL/CM映射、显示变化、资源耗尽回退、物理信号、移动/最低系统及性能均保留为未完成项；这些限制不被本次测试覆盖，生产支持声明保持原样。
