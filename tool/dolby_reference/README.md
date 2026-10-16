# P07 Dolby 参考调查台账

当前阶段已完成固定候选三端arm64构建、首份官方输入盘点和本机有限GPU实验，**Task1 未整体完成**。没有新增播放支持，也没有把现有 FEL 算术测试提升为完整画质结论。

- `baseline.json`：e69d5dc 的现有源码/合成夹具哈希、当前主机上6个检查可执行程序的结果。原始 FEL 媒体缺失，媒体哈希为空。GPU 与手写 scalar 对照仅覆盖既有选定算术点。
- `candidates.json`：固定提交与14个上游源文件哈希、版本和当前构建条件。libplacebo/libdovi 未接入；后续三端arm64构建记录在 `build-evidence.json`。历史PATH预检仍保留；PATH/pkg-config 未发现依赖仅是本机预检结果，不表示这些平台不可能构建。
- `sample-candidates.json`：Dolby 官方仓库6个公开样本线索及 LFS 声明哈希。Task1B1已核实发布方CC BY 4.0声明并下载核验其中P5 1080p，首RPU观察另记 `sample-observation.json`；其余5份未下载，均不是独立参考图。不得据此升级历史调查行的画质或信号状态。
- `cases.json`：6个 Profile 调查类别 × 4组 CM/level 调查条件，共24行，每行三平台独立状态。组合的适用性待原始流确认；不是宣称全部组合均为规范有效流。L3/L9/L10/L11等其他level仍须在真实样本盘点后扩展，当前24行不穷举所有合法元数据组合。

```sh
python3 -B -m unittest discover -s tool/dolby_reference -p 'test_*.py'
python3 -B tool/dolby_reference/inventory.py
python3 -B tool/dolby_reference/inventory.py --check-snapshot
```

普通校验退出0只表示调查台账完整，摘要仍为 `task1: incomplete`、画质/信号通过数0；退出2表示台账非法。schema1 禁止直接改为passed或将合成/LFS声明当作参考。实际取得样本、独立目标图与容差后，须用可核验的新证据和经复审的schema扩展进入验收阶段，不删除已有缺口来得到绿色状态。

`--check-snapshot` 比较当前源码与本次冻结哈希，后续修改生产文件时允许此历史快照不再匹配；应记录新基线，不能篡改旧运行证据。日常基础检查只校验调查结构，单元测试用临时文件验证哈希变化、越界和重复条目拒绝。

重新运行现有基线（macOS + Xcode，GPU/IOSurface需正常主机权限）：

```sh
sh tool/apple_fel/run_tests.sh
bash tool/apple_hdr/run_fel_compositor_tests.sh
sh tool/apple_hdr/run_tests.sh
```

不能据此宣称 iOS物理设备、Android、原始FEL、完整CM映射、外接DV输出或持续性能通过。完整发现及下一验证实验见 [P07报告](../../docs/superpowers/reports/2026-09-26-remaining-07-dolby.md) 和 [映射契约](../../docs/superpowers/specs/2026-09-26-dolby-mapping-contract.md)。

Task1B1复现、初始失败及最终边界见 [构建探针说明](probes/README.md)。调查/证据测试当前12项；本机上游libplacebo13项通过、1项GPU跳过，libdovi2项单测及5个C API退出预期匹配。iOS/Android仅构建链接，尚无设备运行结论。

2026-09-29 Task1B2补充：[runtime-evidence.json](runtime-evidence.json)记录Apple M1原生CGL上游GPU实验和条件分支缺口。复现见[探针说明](probes/README.md)。现有测试发现新增可选真实GPU检查：默认12通过/1跳过，设置 `YL_DOLBY_CGL_PROBE_ROOT` 后本机13通过。原EGL跳过记录不变；Task1仍缺原始FEL、独立参考/容差及移动端/物理链路。

## 2026-10-16：全片 RPU 盘点

新增 `stream_inventory.py`、固定 libdovi3.4.0 的批量解析器及 [stream-observation.json](stream-observation.json)。历史 `sample-observation.json` 保留首RPU观察；新记录覆盖同一未修改官方 P5 文件的6314个视频数据包。完整哈希/时间戳轨迹保存在 `stream-trace.jsonl.gz`，不包含媒体、RPU原文或文件路径。

该探针只接受一个HEVC视频轨道、具有明确样本总数的有限本地MP4。先检查顶层box尺寸不超出文件、数据包均位于mdat内，再要求容器声明的nb_frames与实际读取包数一致；拒绝分片、开放尺寸或无法证明覆盖范围的输入。读取ffprobe报告的原文件偏移和hvcC长度字段，提取原始NAL（含HEVC头、不含MP4长度前缀）。每个视频数据包必须含VCL和恰好一个RPU，否则拒绝完整盘点，不猜测遗漏或多RPU的关联。PTS/DTS为原始整数，时间基为有理数字符串；轨迹按PTS排序，不把解码顺序当呈现顺序。未解码画面，未验证数据包与实际显示帧对应，也未解析复用元数据的有效状态。

已验证：文件SHA-256与原记录相同；6314个RPU均为解析器报告的P5/CM2.9，均含L1/L2/L4/L5/L6；显示元数据完整序列化结果有5107次变化，72个`scene_refresh_flag=1`；5392个数据包的解码/呈现顺序序号不同。这些计数不等于镜头数或已执行trim，不能推导画质。首RPU哈希与历史167字节记录一致。合法新level保留在盘点中；解析器不能处理的内容导致退出2，不将其自动判为媒体损坏。

资源边界：媒体≤512MiB、单数据包≤8MiB、视频数据包≤32768、单RPU≤64KiB、批量RPU输入≤32MiB；ffprobe输出≤16MiB、解析器输出≤128MiB，各子进程期限60秒。超限或非零退出不发布部分成功结果。源文件和解析器在执行前后重验哈希；可选轨迹文件以600权限独占创建，拒绝已有文件和符号链接。无解码、重封装、位流改写、GPU/设备调用或依赖下载。ffprobe仅为离线研究工具，不改变生产FFmpeg依赖。

复现时先构建一次新的隔离输出目录（需要Task1B1已固定的本地归档、官方Rust工具链和Cargo缓存）：

```sh
p07_probes="$PWD/.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes"
python3 -B tool/dolby_reference/probes/build_stream_inspector.py \
  --probes "$p07_probes" --output /tmp/p07-stream-inspector-new
python3 -B tool/dolby_reference/stream_inventory.py \
  --media "$p07_probes/sol-levante-p5-1080p.mp4" \
  --sha256 87fe0115f3002a621d2380a9f91852ef91a15854a446efe26de8744f77ef5346 \
  --inspector /tmp/p07-stream-inspector-new/target/release/yl-dovi-stream-inspector \
  --trace "$p07_probes/stream-trace-new.jsonl"
```

构建器核验固定源码归档SHA-256后重新解包，用提交的Cargo.lock运行`--locked --offline`测试/构建。缺归档、缓存或工具链应先恢复这些已固定依赖；不会转用浮动版本。Rust framing测试随构建执行；Python测试已进入既有`check_foundation.sh`发现入口。默认全量发现33通过、1项既有GPU检查跳过；Rust另3项通过。本次不设置GPU opt-in变量。

CLI退出0只表示完整的**输入元数据盘点**，`mapping_quality`、`native_dv_signal`仍为`external_missing`。独立参考、完整映射容差、原始P7 FEL、移动设备及物理DV链路仍缺，Task1B2整体与CAP-DV-MAP/CAP-DV-OUT未完成。素材沿用原记录的CC BY4.0及Netflix/Dolby署名；本增量为派生元数据清单。

### 现有生产 FEL 准入检查（不占用设备）

默认 Python discovery 现在也执行 `tool/apple_fel/run_tests.sh` 的配对/元数据校验及 `tool/apple_fel/run_failure_tests.py` 的真实错误发布检查。后者编译生产Swift、Pigeon和现有框架，仅调用元数据/错误方法，不创建播放器、Flutter引擎、解码器或GPU。需要macOS、Xcode及已缓存的Flutter macOS框架；可用`FLUTTER_ROOT`指定SDK，缺依赖退出77，在发现入口明确记为跳过。

检查覆盖损坏/不支持区分、schema v1字段、L1/L5/L6、L5空区域、桥接unsupported码、资源类别和安全错误封装；不证明CM显示映射、物理信号或真实样本画质。历史基线快照继续绑定原提交；新生产源码变化不能据此改写历史快照。
