# macOS CAP-FORMAT 同构建验收

在 MacBookPro17,1（Apple M1，macOS 27.0.1 / 26A434）上，用公开 Flutter 播放器逐一运行 22 份固定素材的本地文件和受管 HTTP 场景。每轮独立冻结一个 Debug 应用。基线来自 `44092acbfcf917c4a68eb7f67cb60f36cba7e1f9`，候选在此基础上修改了 Apple 错误码发布和 Dart 错误提示。两轮各自核对了制品身份，未跨构建合计通过数。

| 构建 | 应用 SHA-256 | 运行项 | 通过的必测项 |
| --- | --- | ---: | ---: |
| 修复前 | `be28417ff8767a9ac0597ef35609c872aa722c34cf7ba107bc1840ebcfaf3fc0` | 44/44 | 37/40 |
| 修复后 | `025bd34513d6eb51b22a210b61d13691eefea41625aa802bdd07013fe7f8d93f` | 44/44 | 37/40 |

[基线逐项结果](evidence/2026-10-31-macos-format-matrix/baseline/matrix-result.json) · [候选逐项结果](evidence/2026-10-31-macos-format-matrix/candidate/matrix-result.json)

## 必测缺口

| 素材 | 传输 | 本轮实测 | 通过仍需什么 |
| --- | --- | --- | --- |
| MP4 · AVC/AAC | 文件 | 已首帧、播放至结束并释放。播放和三次 seek 的画面与预效果 PCM 均通过；严格检查返回 `played_sample_clock_unverified`。相同素材的 HTTP 路径通过。 | 需要把当前 AVPlayer 会话的 PCM 与音频输出端实际消费的采样位置关联。 |
| MKV · AV1/Opus | 文件、HTTP | 两次均在视频解码阶段返回 `decoder.unavailable`，没有输出帧。 | 当前仅有 M1。软件路线需要和此机型、系统、解码器及产品构建匹配的持续热负载、资源基线和独立复验，才能建立生产准入记录。 |

本地 MP4 的 tap 记录输入队列拉取 PCM 的时点。独立 Core Audio 进程 tap 也只提供进程输出音频，单凭它仍不能确定哪个样本已由播放设备消费。[本地 MP4 子结果](evidence/2026-10-31-macos-format-matrix/candidate/mp4-avc-aac-file-result.json) · [Apple Core Audio 进程 tap 说明](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)

独立 VideoToolbox 探测使用同一份 AV1 Main 8-bit 素材及其 10-bit 派生输入。三种策略各创建两代会话，十二次 AV1 创建均返回 `-12906`，输出 0 帧。AVC 对照六次各输出 96 帧。这个结果限定于本机。[解码会话原始结果](evidence/2026-10-31-macos-format-matrix/videotoolbox.json)

## 已修复的错误

32 字节截断 MP4 经 HTTP 打开时，解封装器已生成 `container.mp4_open_failed`，但 Apple 错误发布层丢弃了这个包内定义的代码，Dart 也缺少对应提示。现在应用公开返回 `container.mp4_open_failed`，建议使用编码受支持的完整 MP4 文件。消息来自固定文本。截断本地文件仍由 AVPlayer 返回 `avplayer.-11829`。两项损坏输入及两项 MPEG‑2 PS 诊断输入均在必测分母之外。[修复前 HTTP 错误](evidence/2026-10-31-macos-format-matrix/baseline/mp4-truncated-http-status.json) · [修复后 HTTP 错误](evidence/2026-10-31-macos-format-matrix/candidate/mp4-truncated-http-status.json)

Dart 错误模型测试 23 项通过。macOS 原生 MP4 打开错误回归 1 项通过，0 项跳过。两套矩阵均保留了完整计划、逐场景原始记录和产品逐文件哈希。解压各目录的 `records.json.xz` 后可用 `tool/media_matrix/bound_matrix.py` 的 `summarize` 与对应的 `matrix-plan.json` 重放。CAP-FORMAT/macOS 仍为 `partial / failed`。

构建参数见[公开 Flutter 测试入口](../../../tool/media_matrix/BOUND_AV.md#apple-public-flutter-build-bound-collection)。[原生回归结果](evidence/2026-10-31-macos-format-matrix/native-test.json) · [归档哈希清单](evidence/2026-10-31-macos-format-matrix/sha256.json)（SHA-256 `e852b5657305986e0fe9e9442d39c44082ba42dbfeefd4a945ac0980ea1f4ce4`）。
