# macOS DTS 独立 PCM 验证

固定素材 `mkv-avc-dts` 的 DTS Core 双声道输出通过逐样本对照。在 M1、macOS build 26A434 上，矩阵应用内的 codec 桥接与独立解码器各消费 375 个压缩包，输出 192,000 个 48kHz 采样帧。全程按原始左右声道顺序比较，左右声道最大绝对误差分别为 0.000000685 和 0.000000585，低于仓库已有的 0.0002 门槛。[完整回执](evidence/2026-11-03-macos-dts-independent-pcm/result.json)

参考实现使用 OxideAV 的独立 Rust DTS Core 解码器，固定提交 `ec55712f152b93a7638aab3e5c297532d7aa23ae`。参考程序保留跨包合成状态，输出交错 S32LE，以 2³¹ 归一化。FFmpeg 在正式比较中只读取包元数据和复制压缩字节，每包校对原始哈希。产品 Float32 输出直接取自签名矩阵应用中的 `ylf_dts_decode`，桥接哈希与归档播放进程所加载的映像相同。[参考源码](https://github.com/OxideAV/oxideav-dts/tree/ec55712f152b93a7638aab3e5c297532d7aa23ae) · [工具版本和来源](evidence/2026-11-03-macos-dts-independent-pcm/provenance.json)

复用已通过的 40/40 矩阵记录。文件与受管 HTTP 各有四个播放窗口及三个 seek 窗口，全部 14 个窗口各比对 8192 帧，最大绝对误差为 0.000000391。定位使用每包实际 PTS 和包内样本序号。512 帧对应 10⅔ms，而此 Matroska 的时间戳精度为 1ms。例如 250ms 窗口在原始流中从第 12,016 帧开始。整个比较使用固定幅度单位和时间映射。将起点错开一帧或对调左右声道，两项负对照分别以 0.002224 和 0.041569 的误差被拒绝。[矩阵原始记录](evidence/2026-11-03-macos-qualified-format-matrix/final-matrix/records.json.xz) · [复现命令](../../../tool/media_matrix/dts_reference/README.md)

本轮覆盖该 DTS Core 素材的完整原始解码和公共文件／HTTP 的播放与 seek 窗口。多音轨真实切换的独立 PCM 对照和其他设备输出边界仍待验证。
