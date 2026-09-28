# P07 执行报告：Task1 参考、候选与完整性门槛

2026-09-28；当前增量基线 `e69d5dc47db3dc08a808dd73c80de56acd446a4d`，工作区最初干净。**Task1 部分完成：基线与调查台账已交付；原始FEL、独立参考、最终容差及候选三端构建尚未齐备。CAP-DV-MAP / CAP-DV-OUT 均未完成。** 本次没有修改生产播放器、放宽元数据拒绝或新增依赖。

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
