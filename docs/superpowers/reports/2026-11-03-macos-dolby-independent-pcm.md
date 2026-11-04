# macOS AC‑3 与 E‑AC‑3 独立 PCM 对照

上一轮同构建格式矩阵中的 AC‑3 5.1 和 E‑AC‑3 双声道素材已通过独立解码对照。固定的 OxideAV Rust 实现与已签名矩阵应用内的 codec 桥接分别解码相同的 125 个包，每包 1536 帧。两种素材各输出 192,000 帧。沿用已有 Dolby 桥接检查的绝对误差上限 0.0002，逐样本、逐声道比较，从首帧直到末帧。[独立参考实现](https://github.com/OxideAV/oxideav-ac3/tree/1a2e96db770d5d113811d97df3a59e1dbfc2bb5f) · [逐声道和逐窗口结果](evidence/2026-11-03-macos-dolby-independent-pcm/result.json)

| 固定素材 | 声道 | 整段最大绝对误差 | 文件及 HTTP 窗口数 | 窗口最大绝对误差 |
| --- | ---: | ---: | ---: | ---: |
| MKV AC‑3 | 6 | 0.000098482 | 14 | 0.000042604 |
| MKV E‑AC‑3 | 2 | 0.000082923 | 14 | 0.000070972 |

比对绑定矩阵应用清单 `0d16457b02dc4cb6e53b8e7ed4aea06cd34136be3e3cbe82430e0495e0db8dbf` 和实际加载的桥接映像 `4a2083b42c52de082d170f1aced30c6fff67b8e93e40961068b2b2ac0e62dd5d`。原始包通过 stream copy 提取并逐包核对哈希。参考解码器直接输出 WAVE 声道顺序的 S16，按 32768 归一化后与桥接 Float32 比较。公共文件和受管 HTTP 的证据取自同一矩阵原始记录，每路四个播放窗口加三个 seek 窗口，每个窗口含 8192 帧。比较起点由媒体时间、首包 PTS（−5000µs）和采样率直接计算。负对照将参考错开一个采样帧，或交换产品左右声道，两次均被原门槛拒绝。[矩阵原始记录](evidence/2026-11-03-macos-qualified-format-matrix/final-matrix/records.json.xz) · [版本与负对照回执](evidence/2026-11-03-macos-dolby-independent-pcm/provenance.json)

最初尝试的 macOS 系统解码器对两份原始码流均返回 191,712 帧，少 288 帧。包表覆盖及额外静音保护包的诊断没有建立符合既有门槛的首尾对应关系，此路径未用于通过判定。

本轮完成两份固定素材的原始解码边界和公共播放／seek 窗口对照。真实切轨的独立输出、DTS 的独立解码参考以及跨设备输出边界仍待验收。[复现步骤](../../../tool/media_matrix/dolby_reference/README.md)
