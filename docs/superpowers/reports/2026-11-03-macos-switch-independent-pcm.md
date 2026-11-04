# macOS 原生后端音轨切换的独立 PCM 验证

同一 macOS managed 播放会话在四音轨 Matroska 素材上完成四次真实切轨。每次先暂停、seek 到 2.5 秒，再选择下一轨并播放到结束。测试从会话状态读取切换前后的实际选中轨，在生产音频转换器完成目标时间裁剪后保留 PCM。四次的首个保留块均从 2,500,000µs 开始，逐块 PTS、块长、总帧数和逐样本误差均通过。峰值绝对误差门槛为 0.0002。[逐轨回执](evidence/2026-11-03-macos-switch-independent-pcm/result.json)

| 实际切换 | 输出声道 | 切换后完整帧数 | 最大绝对误差 |
| --- | ---: | ---: | ---: |
| AC‑3 → E‑AC‑3 | 2 | 71,760 | 0.00005662 |
| E‑AC‑3 → DTS | 2 | 72,000 | 0.000000559 |
| DTS → FLAC | 2 | 72,000 | 0 |
| FLAC → AC‑3 | 6 | 71,760 | 0.00010337 |

独立工具直接读取本次四轨素材中各自的压缩包，核对原始包哈希，并按包的 PTS、采样率及向前取整的样本裁剪量确定参考起点。Dolby 和 DTS 使用上一轮固定的 OxideAV 实现，FLAC 使用主机 FFmpeg 对照产品 Core Audio 转换器。四条完整参考流分别与既有参考哈希相符。Dolby 素材首包 PTS 为 −5ms，故相同切换时间下，保留帧数比另外两轨少 240。负对照将旧 E‑AC‑3 轨的 512 帧放在新 DTS 轨开头，第一个采样即被拒绝，误差 0.012386。[来源与负对照](evidence/2026-11-03-macos-switch-independent-pcm/provenance.json)

本次使用 M1 上的 Debug XCTest 宿主，真实后端、解封装、音频转换和平台音频输出参与，测试控制显示 tick。样本记录点为转换后 PCM。回执绑定此次载入的 SDK 和 codec 映像。公共 Flutter 入口的切轨、音频路由变化及其他设备的输出仍待验收。早期参考命令把 FLAC 输入选项用于所有音轨，FFmpeg 在探测其他轨时报告错误。最终命令将解码器限定为第四条音频流并启用遇错退出，严格重放通过且结果相同。[XCTest 回执](evidence/2026-11-03-macos-switch-independent-pcm/test-summary.json)

复用上两轮独立解码工具可重放归档。先将 [XCTest 附件](evidence/2026-11-03-macos-switch-independent-pcm/attachments.tar.xz) 解压到新的工作目录，然后从仓库根目录执行：

```sh
e=docs/superpowers/reports/evidence/2026-11-03-macos-switch-independent-pcm
python3 -B tool/media_matrix/verify_track_switch.py \
  /absolute/exported-attachments "$e/test-summary.json" \
  build/macos-dolby-reference/oxideav-ac3/target/release/examples/yl_reference \
  build/macos-dts-reference/oxideav-dts/target/release/examples/yl_dts_reference \
  build/switch-replayed.json
```
