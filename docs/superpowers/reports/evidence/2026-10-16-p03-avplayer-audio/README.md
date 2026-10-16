# P03 AVPlayer 公开 Flutter 音频观测

基线 `4fc3a86`，沿获批 P03 Task 7 实施。当前环境已补上本地 MP4 的真实 PCM、显示层画面、三次 seek 和 tap 释放观测；**严格音频消费位置仍未获得，完整 P03 未完成**。这是明确分离的 `renderPullAcceptance`，不能升级为 `scopeAcceptance` 或完整格式通过。

## 实现与边界

仅 `DEBUG && YL_BOUND_AV` 构建在产品实际选择的 AVPlayerItem 上安装 pre-effects MTAudioProcessingTap。原样透传 PCM，不增加解码器或替换音频输出。每次 seek 使用独立 tap/storage/epoch，迟到回调不能进入新阶段；固定容量存储通过原子发布不可变槽位避免报告线程阻塞或丢弃音频回调。PCM 溢出或无效定时样本拒绝证据；priming/drain 中没有媒体时间的取数单独计数，不推进观察时间。

音频持续运行，真实附着显示层只在像素读回时短暂冻结、随后恢复。四个初播 marker 及 seek 1250/2250/0 ms 的七个固定 8192 帧原始窗口由独立 Python 门禁检查频率、幅值、声道身份、窗口位置及画面标记。source range 和实际 frame count 分别保存；选择窗口时按 source interval 映射样本，不把该映射称为硬件样本呈现时间。既有 fallback 保留原精确时间运算及公共暂停协议。

AVPlayer tap 暴露音频队列源数据取数区间，未暴露硬件已播放样本计数。`audioClockMethod=avplayer-preeffects-source-pull`、`audioEvidenceBoundary=audio-queue-source-pull`、`audioReadbackProtocol=continuous-source-pull-v1` 明确该边界。严格门禁始终报 `played_sample_clock_unverified`；更改 method 标签也不能将 tap 数据伪装成既有消费证据。公开 dispose 后先观察 host disposed，再释放 probe 对 host 的引用，等待实际 tap finalize，避免观察器自身延长 AVPlayer 生命周期。没有伪造 AVPlayer released-byte 计数。

本轮只覆盖自有 clear 本地单音轨、float32 mono/stereo tap 可接受格式，最终公开正控是 AVC/AAC MP4。未改变网络 managed、解码准入、生产调度或 long-play/弱网 ABR。远程/DRM/多音轨、硬件播放头、物理输出、release、独立解码参考、最低系统/Intel 和持续热资格不由此覆盖。

## 最终验证

每个平台先冻结一个真实 Debug 应用，运行前由原生代码核验实际 bundle/加载镜像/媒体字节，所有记录绑定同一公开及原生 session。结束后再次核验 bundle 未变。原始文件在对应目录，`product-files.json` 与 `plan.json` 保存完整身份。

| 最终运行 | 原始取数观测 | 严格消费验收 | 框架结果 |
| --- | --- | --- | --- |
| macos-final-positive：本地 MP4 | 1/1 通过 | false，消费头缺失 | 通过 |
| ios-final-positive：本地 MP4 | 1/1 通过 | false，消费头缺失 | 通过 |
| macos-final-controls：既有六控制 | 不适用 | 6/6 通过 | 通过 |
| 两端 negative-framework | 原始 MP4 取数记录通过 | false | 故意失败，总体拒绝 |
| 两端 negative-identity | 播放前拒绝，零行 | false | 拒绝 |

Apple runner 的退出码仍由严格 `scopeAcceptance` 决定，因此正向 MP4 的 CLI exit 1 是预期边界，不是完整验收通过。macOS `processExit=-15` 为框架最终状态已落盘后的宿主清理；iOS 进程结束码也不替代框架最终状态。既有完整格式矩阵 Android36/40、macOS32/40、iOS0/40 是前一冻结构建的严格结果，本轮不与它拼接、不增加通过项。

- macOS 受影响原生 **45/45**，零失败、零跳过，包含新建真实 WAV 的 tap PCM、seek 隔离及 finalize 测试。`native-current-summary.json` 和完整压缩日志保存原始统计。
- Flutter example **96/96**；两个改动 Dart 文件静态分析通过；公开 API surface 检查通过。
- Python media_matrix **61/61**；新增边界、迟到 epoch、无效 range/frame、未释放和重新标记伪装等负例。
- macOS/iOS Simulator 最终公开构建通过；既有编译警告保留。普通 macOS Debug 与带 opt-in define 的 Release 均无采集类符号，显式 Debug 含采集类；实际产品 registry 为扫描正控。
- 三份 YlPlatformServicesTests 镜像相同。`post-run-product-verification.json` 为最终运行后的冻结产品复核。

## 失败历史与复核

`history/baseline` 重现实际 MP4 播放中无 renderer/零 PCM。原生初次测试失败揭示无效/零时间 priming、负 preroll、source range 与输出帧数不等，以及测试自身保留 item 的问题。每份原始失败日志均保留。

`history/macos-mp4` 保留 observer 持有 host 导致 finalize 缺失；`macos-mp4-release` 的 post-effects 与 `macos-mp4-preeffects` 的频繁暂停采集均存在真实 PCM 不连续，不能当作通过记录。`macos-mp4-continuous` 首次通过独立取数门禁；最终两端重新构建并实跑。`history/macos-controls` 为共享去重/时间换算误影响 DTS、Vorbis 的 4/6 失败；将新映射和暂停仅限 AVPlayer 后，最终同一冻结应用六项重新验证为6/6。没有放宽 PCM、画面容差或缩小分母。

工具调用失败也保留：Flutter 配置并发时 SPM resolve 失败后串行成功；错误 cwd 的 example 测试92通过4失败后按正确工作目录96通过；缺少 `--root` 的 API 检查用法错误后纠正；xcresulttool 临时目录写权限错误后以授权方式导出。它们不充作产品回归证据。

独立复核结果及范围见 [final-review.md](final-review.md)。复核发生于后续连续 pre-effects、原子存储和 fallback 隔离修复之前；后续变更由主执行者以最终原始实跑、原生测试和边界负例验证，不声称最终 diff 获得第二次独立复核。

## 重放与身份

在仓库根目录运行：

```sh
python3 -B docs/superpowers/reports/evidence/2026-10-16-p03-avplayer-audio/replay.py
```

脚本解压原始 PCM，重新运行门禁，验证正向只通过取数边界、六控制严格通过、负例拒绝及完整归档 SHA-256 清单；不依赖缓存通过标记。`build-provenance.json` 保存最终构建对应源文件 SHA；`commands/` 保留实跑命令，二进制和 xcresult bundle 在本机 scratch，未提交。

提交前另一会话新增 `af9cc10`（P07 Dolby 元数据工具/文档，39个路径）；检查无本轮产品/验收源依赖改动，最终源摘要一致。保留该父提交，只提交本轮明确文件，不推送。
