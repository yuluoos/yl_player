# P07 公开素材与双层输入核验（2026-10-20）

基线 `ab73405190a1996f8d081236d7bb48865c47dbdc`；隔离分支 `codex/p07-engineering`。本次完成原计划 Task1 的公开资源获取和单轨双层输入盘点增量。**P07 全部工程功能尚未完成**：完整 CM/trim/目标映射和三端原生 DV 信号仍未验收，不提升 CAP-DV-MAP/OUT。主目录、投屏、媒体拆分及现有 FEL 像素算法未修改。

## 实际取得的资源

机器可读来源、大小、哈希及官方 XML 显示参数见 [public-resources.json](../../../tool/dolby_reference/public-resources.json)，P7 单独见 [fel-observation.json](../../../tool/dolby_reference/fel-observation.json)。原字节文件保存在本工作树忽略目录 `.superpowers/sdd/2026-10-20-p07-public-resources/resources/`，未提交媒体。

| 资源 | 实际取得与核验 | 可证明的范围 |
|---|---|---|
| 社区 FEL TEST ST DL P7 CMV4.0 4000nits V4.mp4 | 52,039,065 字节；SHA-256 `419fc183988cb57b0cac2907a01d9f43b1a5ec34012b4c0655574d77678ee4fa` | 可读取的双层功能输入；不证明原始制片/编码链或独立目标画质 |
| Netflix Sol Levante XML | 203,263 字节；24 fps，72 shot，记录结束 6314 | 官方母版元数据；1000 nit P3 mastering、100 nit Rec.709 target |
| Netflix Sparks XML | 311,836 字节；60000/1001 fps，39 shot，记录结束 13777 | 官方 4000 nit mastering；100/600/1000/2000 nit 目标及各自色域/黑位 |
| Sparks 原始 EXR 01000 | 53,119,100 字节；4096×2160 RGB half float；解码退出 0 | 来源独立的母版帧候选 |
| Sparks HDR10 1000 nit TIFF 01000 | 53,084,342 字节；4096×2160 RGB 16-bit；解码退出 0 | 官方发布目标序列候选；尚未成为合格 golden |
| Netflix CC BY 4.0 说明 | 105,020 字节，已留原文件及哈希 | 官方素材使用依据及署名；不套用于社区媒体 |

### 来源核实

- [Netflix Open Content](https://opencontent.netflix.com/) 明确发布 Sparks 的 4000 nit P3/PQ EXR、Dolby Vision XML、1000 nit PQ/2020 TIFF 序列，以及 Sol Levante 母版和 XML，采用 CC BY 4.0。目录链接的虚拟主机 URL 在本机遇到证书主机名不匹配；使用同一公开 S3 bucket 的 HTTPS path-style endpoint，保持证书验证，成功获取原文件。
- [Dolby 官方 dolby-vision-contents](https://github.com/DolbyLaboratories/dolby-vision-contents) 当前列出六份 P5/P8.1/P8.4，未列 P7；已有 P5 原片继续复用。[Dolby Browser Test Kit](https://ott.dolby.com/browser_test_kit/help_files/topics/r_test_signals_all.html) 提供更多播放测试源，未在该目录找到能直接满足 P7 FEL 独立目标参考的材料。
- [Kodi Samples](https://kodi.wiki/view/Samples) 指向 [DV FEL TEST 目录](https://drive.google.com/drive/folders/1V-onFW4PwgKAFdVlwXeuKOnUvdZXqsY6)。本次取得的是 [ST DL MP4 文件](https://drive.google.com/file/d/18rS2XZwwcweJ4_xIUwJfa5SllCYkqa1f/view)，没有取该目录中的电影片段。下载未改 RPU、去层、转换 Profile 或重封装。社区测试片的原始生成链和分发许可未核定，故只保存本地功能研究副本与派生盘点，不把媒体加入 Git。
- [dovi_tool 作者解释](https://github.com/quietvoid/dovi_tool/discussions/168) 的改写/移除 mapping 示例不能当成完整 FEL 原始输入证明。本次未使用其衍生 P5 转换文件。

## 新增工程能力

`stream_inventory.py --layers` 在既有单 HEVC 轨道有限 MP4 的资源边界内，检查 layer-zero NAL 头和 UNSPEC63 内部头，记录每包 BL VCL、EL VCL、EL NAL 数量及增强层原字节哈希。哈希输入为每个原始 EL wrapper 的四字节大端长度加 wrapper 字节，独立于 MP4 的 NAL 长度字段宽度。EL 参数集不算画面；多个 slice 不算多帧。截断/嵌套 wrapper、非法头或本探针不支持的 layer ID 会拒绝完整盘点，退出 2 不意味着生产播放器认定媒体损坏。

默认不加参数仍输出 schema1；加 `--layers` 输出 schema2 和逐包覆盖轨迹。P5 历史文件重扫后，除重建 inspector 可执行文件哈希外，所有旧摘要值与完整 trace 哈希均与历史证据一致。

P7 全片结果：

- 容器声明 2908 个样本，读取 2908 个视频包和 2908 个 RPU；每包各一个 BL VCL 和 EL VCL，缺 EL VCL 包数 0；EL NAL 总数 9578。
- 固定 libdovi 3.4.0 报告全部为 P7 FEL，均有 CM2.9 与 CM4.0；levels 为 1/2/3/4/5/6/8/9/254。并存不能解释为二者同时生效。
- 元数据指纹变化 2727 次，`scene_refresh_flag=1` 34 次；不把这些计数称为镜头数。2114 个包的解码/呈现序号不同。
- 保存 [全片轨迹](../../../tool/dolby_reference/fel-trace.jsonl.gz)；整数 PTS/DTS、每包原 RPU 和增强层哈希均保留。
- 尚未解码这段视频进行 BL/EL POC 配对或有效元数据继承验证。NAL 齐全不等于像素重建正确。

## 独立参考仍缺的具体条件

本次获得了官方来源独立的图像，但没有达到原契约的质量判定门槛。Sparks 同编号 01000 帧处于 XML 的 `[917, 1484)` 段，段内 trims 为目标 ID 1/27/48；公开 1000 nit Rec.2020 序列与哪个输出配置、哪个版本及转换路径对应仍待核实，不能仅由目录名推断。EXR 原始头没有明确色彩域/EOTF 属性；ffprobe 自动给出 linear 标签，而发布说明标为 P3/PQ。此标签不能覆盖发布信息，转换必须另行核验。两帧能解码、尺寸相同和文件名相同仍不构成同帧/同 grade 证明。

社区 FEL 测试片与 Sparks 是不同素材，不能相互充当输入/目标图；目前仍缺社区 FEL 的对应独立重建/目标输出、完整适用元数据的参考公式/向量以及事先冻结的容差。固定开源候选尚未证明完整 CM2.9/CM4.0 trim。没有按本次可用素材擅自放宽现有 L1/L5/L6 准入边界。

官方 [制作流程文章](https://netflixtechblog.com/engineers-making-movies-aka-open-source-test-content-f21363ea3781) 及 [资产 README](https://s3.amazonaws.com/download.opencontent.netflix.com/TechblogAssets/README.txt) 进一步明确区分 P3-D65 PQ、output-referred 的 VDM 与 ACES linear 的 GAM/NAM。README 已下载保存哈希；这支持按发布者的 PQ 描述调查 VDM，而不能因扩展名为 EXR 或 ffprobe 默认标签就视为 linear。该说明没有提供本次下载的 1000 nit TIFF 与其源帧/目标配置的精确生成契约或最终容差，因此候选资格保持未完成。

## 外接链路调查

[Apple 官方说明](https://support.apple.com/en-ie/105099) 给出可作为后续实验的链路：支持外接显示的 USB-C iPhone → Apple USB-C Digital AV Multiport Adapter → 支持 Dolby Vision 的 HDMI 电视。官方支持输出格式并不证明本播放器的 P7 FEL 路径；本会话尚无实际设备型号/OS、转接器、电视固件/模式、信号捕获及全屏/热插拔/后台恢复实测。物理输出保持 `external_missing`，不能通过网络搜索变为通过。

## 验证

- 新的 7 项层盘点测试先失败：6 个用例因新参数未实现报错、1 个旧兼容用例通过；实现后 7 项通过。随后加 CLI 贯通和失败无部分轨迹测试。
- 最终完整 Python 发现 49 项：48 通过、1 项既有 opt-in CGL GPU 跳过；包含既有 Apple FEL pairing、metadata、公有错误封装宿主回归及新增轨迹证据检查。调查台账退出 0，仍明确 Task1 incomplete、映射/信号通过数 0。
- 固定源码/缓存离线重建 inspector，Rust framing 3 项通过；实际 P7 全片盘点成功；P5 默认输出回归成功。
- FFmpeg 8.0.1 对取得的两张官方图各解码一帧，均退出 0；不是生产映射或 GPU/设备测试。
- 验证日志位于 [evidence 目录](evidence/2026-10-20-p07-public-resources/)。本增量无 Dart/Flutter、生产 native 或依赖变化，未重复整仓设备集成测试。

## 独立审查与修正

独立审查复算实际媒体的全部 2908 包，原时间戳、RPU 哈希与层统计匹配。发现 header-only VCL 被误计为覆盖：新增 BL/EL 无载荷拒绝与 CLI 不发布 trace 的测试，先观察失败，再修复；最终 49 项测试 48 通过/1 既有 GPU 跳过，真实 P7 重扫摘要和轨迹哈希不变。该检查只排除明确的无载荷截断，仍不验证完整 slice 语法。验证日志从被忽略的 `.log` 转为已收录 `.txt`，避免新检出缺证据。审查与修复记录在 evidence 目录，文件清单绑定 SHA-256。

审查未评价完整 slice/POC/有效元数据继承、原始生成链/独立目标资格/完整 CM，以及真实信号/目标显示切换；这些均遵循本增量的未验证边界。错误地把盘点结果提升为这些能力的证据会产生错误画质或输出声明，因此所有对应能力继续待验证。

## 下一步解除条件

继续核验官方图像序列的精确生成/对齐契约，并取得 FEL 同源独立参考；冻结亮度、色域、黑位、时空位置和阈值后，按被证实的元数据子集实现映射。物理 DV 信号另外安排实际链路。P07 Task1 整体及 Task2/3/4 不勾选完成；本增量可以独立审阅，不代表“全部工程功能”交付。
