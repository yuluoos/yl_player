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
