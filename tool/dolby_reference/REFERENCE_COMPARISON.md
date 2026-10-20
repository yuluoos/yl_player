# 参考时间轴与离线数值比较

这是 P07 的研究/验收工具，不是播放引擎。它核验给定文件、元数据和操作者预先冻结的比较合同；不会证明参考文档的真实性、捕获来自指定设备、完整 Dolby 算法或原生输出信号。生产支持矩阵不会自动更新。

## 参考来源和时间轴

`reference_timeline.py` 支持一个 Output、一个 Track 的 UTF-8 DolbyLabsMDF 2.0.5 子集，文件不超过 4 MiB，最多 32768 个连续 shot。从 0 开始的半开区间必须连续、不重叠；重复目标和未知 trim target ID 拒绝。仅记录明确出现的 L2 target ID，未出现的值不视为中性，也不在此解析有效 trim 继承。未知 MDF 版本/结构退出 2，不把研究工具不支持误报为生产媒体损坏。

```sh
python3 -B tool/dolby_reference/reference_timeline.py \
  --xml .superpowers/sdd/2026-10-20-p07-public-resources/resources/sparks-metadata.xml \
  --sha256 a18f5960f61f868932416000c35f08bb39d9966b1dc35a8b6778e9718bb16c0f \
  --frame 1000
```

`locate_pts` 的时间基、帧率和帧号全程使用整数与有理数；PTS 必须恰好落在帧网格上，不做浮点取整。`locate_frame` 解释的是 XML 时间轴位置，不能证明另一个目录的同名图片对应这一位置。`exr_header` 只读取最多64 KiB头部（最多128属性），展示原始timeCode、rate和dataWindow；不从时码推导帧身份，也不验证完整EXR像素数据。

`verify_publisher_asset` 绑定完整官方清单的SHA-256、单条文件名/大小/MD5与本地原字节SHA-256。MD5只用于已有发布清单的文件识别，不用作安全签名；下载来源及SHA-256冻结另有记录。此检查不证明跨序列同帧或目标映射。

## RGB比较合同

示例见 `fixtures/comparison/contract.json` 和 `capture.json`。这是明确标注的2×2合成候选，不能用于DV画质验收。研究依赖固定在 `requirements-reference.txt`，使用已安装 NumPy 的 Python；缺依赖时CLI明确退出2，不会回退到低精度算法。

```sh
# 研究虚拟环境可按需安装：python3 -m pip install -r tool/dolby_reference/requirements-reference.txt
python3 -B tool/dolby_reference/pixel_compare.py \
  --contract tool/dolby_reference/fixtures/comparison/contract.json \
  --sha256 CONTRACT_SHA256 \
  --capture tool/dolby_reference/fixtures/comparison/capture.json
```

`CONTRACT_SHA256` 必须来自观察被测输出之前冻结的合同。CLI校验字节哈希，不能验证冻结时间或代替独立评审；不要在看到误差后改容差。示例的固定哈希见本目录下 `fixtures/comparison/contract.sha256`。任何实际合同应另存其预先批准的哈希。

合同字段：

- `schema_version: 1`；`mode`为`candidate`或`reviewed_reference`。后者是操作者的参考审查声明，不是工具鉴定出的资格。
- `source_sha256`为原输入身份；离线工具检查其与capture一致，实际输入到捕获的来源链须由采集端和独立证据保证。
- `width`、`height`、`domain`定义RGB平面。文件固定为逐像素RGB交错、little-endian float32、绝对亮度cd/m²；domain只允许`linear_nits_bt2020`、`linear_nits_p3d65`、`linear_nits_bt709`。不接受直接把PQ码值、planar GBR、半浮点或SDR截图标成这个格式。
- `target`固定显示峰值、黑位（nit）、primaries、xy白点、transfer和环境照度（lux）。capture必须完全一致。工具不监听物理显示变化；采集端负责重新读取目标并递增`display_generation`，旧代次帧被拒绝，即使目标值恢复相同也不能混用。
- `active_area`为`[x,y,width,height]`。全图始终比较，另需至少一个`boundary`和一个`chroma_edge`矩形；ROI名称唯一。操作者需根据参考证据冻结真正的边界/色度边缘，工具不自动识别边缘。黑边不能仅靠缩小active area排除。
- `thresholds`固定`max_abs_nits`、`rmse_nits`、`p99_abs_nits`三个非负有限阈值，所有区域均需满足。
- `frames`按严格递增时间顺序列出唯一非负整数`id`、有理数秒`pts:[numerator,denominator]`、有效元数据身份`metadata_sha256`及参考`path/sha256`。必须由采集/继承解析证据确认这是有效元数据，不能直接以既有signalled RPU指纹冒充。capture按同顺序提供对应id/PTS/元数据、代次与actual路径/hash。
- `evidence`为带角色的`path/sha256`文件；reviewed模式要求provenance、frame_alignment、target_generation、threshold_basis四项，且至少两帧、两个不同元数据身份。证据内容仍由独立审查解释，工具仅验证字节绑定。candidate允许空证据并始终输出诊断状态。

文件只能位于各manifest所在目录内（包括子目录）；拒绝绝对路径、`..`和解析后逃逸根目录的符号链接。JSON不超过2MiB，重复键/NaN/Infinity拒绝；单证据≤4MiB；最多32帧，单帧≤4096×2160像素、每边≤8192。每帧依次读取，float32输入转float64计算误差。4K比较会使用数百MiB主机内存，不能当作生产内存预算或移动端性能证据。

## 指标和返回值

没有自动归一化、曝光匹配、色域/EOTF转换、重采样或容差回填。每帧每区域给出最大绝对误差、RMSE、最近秩p99（rank=ceil(0.99*N)）和最大误差位置`[x,y,RGB通道索引]`。N包含区域全部像素的三个通道。参考或实际全图任意非有限值、长度/哈希不匹配都拒绝，不能通过裁剪掩盖。

- 退出0：reviewed合同下所有给定数值阈值满足；**仍不是CAP-DV-MAP通过**。
- 退出1：reviewed合同下数值阈值失败。
- 退出2：输入/合同/依赖/资源不合法，输出安全错误码，不输出原路径或输入内容。
- 退出3：候选参考的诊断结果；即使误差为0也不能用于成功验收。

`mapping_quality_pass`和`native_dv_signal_pass`始终为null；前者需要整体独立质量验收，后者需实物链路、切换恢复和信号证据。数值比较不能替代这两项。

## 验证入口

新测试进入现有unittest发现入口。NumPy缺失时，数值测试明确skip，合同与时间轴测试仍执行；正式验收必须使用安装固定NumPy的解释器并记录其版本，不能将skip计通过。

```sh
python3 -B -m unittest discover -s tool/dolby_reference -p 'test_*.py'
```
