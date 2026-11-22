# 小米电视 DASH 起播首帧与跨编码复测

小米 MiTV-MTTP0（Android 9 / API 28，32 位）两次独立运行同一原生测试 APK。起播首帧 30/30 轮在 70 ms 内，AVC → HEVC 边界首帧 6/6 轮超限。两批使用原五组素材和逐帧采集器，限值为绝对音画偏差 ≤70 ms、跨段输出间隔超额 ≤100 ms。[上轮同机数据](2026-11-22-android-mitv-dash-recovery-and-transitions.md) · [冻结限值](../../../tool/dash_timeline/joint_acceptance.json)

| 批次 | 已配对帧数 | 起播首帧最大绝对偏差（ms） | 清单响应备好至首帧释放中位数（ms） | 跨编码首帧最大绝对偏差（ms） | 跨编码间隔最大超额（ms） |
| --- | ---: | ---: | ---: | ---: | ---: |
| 上轮 | 1,514 | 176.957 | 754.3 | 199.274 | 206.298 |
| 本轮首批 | 1,514 | 19.032 | 997.7 | 210.185 | 241.535 |
| 同包复跑 | 1,508 | 19.400 | 999.7 | 256.494 | 271.150 |

## 起播

电视的 AudioTrack 在实际消费 PCM 之前就能返回起始位置。上一轮自动起播先显示画面，15 轮中有 12 轮按 1× 时钟回推超过 70 ms。现在，仅在这台受限电视的非 DRM DASH 已请求播放、有活动音轨且视频解码器拿到首个可显示缓冲时，让 Media3 进入可播放状态。音频渲染器得以启动，播放头前进后释放该帧。取得有效音频位置后等待上限为 650 ms。暂停加载时沿用预览行为。

两批合计 3,022 帧，音频时钟缺失 0 帧。首帧读取的是实际前进的播放头。相比上轮，清单响应备好至首帧释放的中位数增加约 244 ms。该耗时包含本地 HTTP、解析、解码和设备调度。屏幕扫描和扬声器物理输出未测量。

延迟音频初始化响应 160 ms 的三轮均读到消费时钟，最大首帧绝对偏差 11.066 ms。暂停预览对照在调用播放前已读到首帧像素，随后播放至结尾。该场景单列，不与自动起播合并。公开 Flutter 跨段回归 19/19 通过。JVM 共 641 项，638 项通过，3 项跳过。

## AVC → HEVC

自动起播之后，两批全部超限帧均出现在 1.5 秒处的 AVC → HEVC 首帧。两批仍由一个视频解码器串行切换。独立的应用跟踪记录了三轮中 Media3 播放线程调用平台同步 API 的耗时。

| HEVC 阶段 | 三轮耗时范围（ms） |
| --- | ---: |
| 创建实例 | 9.765–12.322 |
| 配置格式与 Surface | 9.550–14.065 |
| 启动解码器 | 112.894–125.446 |

另用独立测试包把真实跨编码素材送入 Android MediaSync 的输入 Surface，再从输出纹理读回像素，提前提交窗口为 250 ms。首轮 AVC 启动期间，设备记录了 `onSidebandStreamChanged: got sideband stream unexpectedly`；GPU 探针关闭时超时，没有取得可核对的跨编码帧行。这个对照无法证明排队画面能够覆盖换代空窗，最终播放器沿用直接输出。测试结束后已恢复最终验收包并核对安装哈希。[Android MediaSync 接口](https://developer.android.com/reference/android/media/MediaSync)


[逐轮帧数、偏差、APK 与源码哈希](evidence/2026-11-22-android-mitv-dash-first-frame-and-hevc/results.json) · [原始采样、JUnit 回执、平台对照源码与跟踪片段](evidence/2026-11-22-android-mitv-dash-first-frame-and-hevc/captures.tar.xz)

归档 SHA-256 为 `b101fee2d5f421b3c054ce3189a1f5d7ce967e0c2b64700c60b54597b67a643a`。解压后可从仓库根目录分别复算两批，第二批的输入文件为 `repeat/samples.log`。严格判定保留跨编码失败退出码。

```sh
python3 -B tool/dash_timeline/joint_observations.py final/samples.log --platform android --limits tool/dash_timeline/joint_acceptance.json --output metrics.json
python3 -B tool/dash_timeline/joint_timing.py final/samples.log
```
