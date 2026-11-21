# OPPO DASH 起播与跨段首帧优化验收

2026-11-21，在 OPPO CPH2065（Android 12 / API 31）上，用同一份最终 APK 独立执行两批严格验收。每批覆盖原有 5 组素材，每组 3 轮。两批共记录 **3,042 个输出帧，全部配到音频消费时钟**。使用原有的 70 ms 绝对音画偏差上限、100 ms 跨段输出间隔超额上限和零缺失要求。[冻结门槛](../../../tool/dash_timeline/joint_acceptance.json) · [优化前的同机对照](2026-11-21-android-oppo-dash-frame-timing.md)

| 同机实测项 | 优化前，15 轮 | 最终 APK，首批 15 轮 | 同一 APK，复跑 15 轮 |
| --- | ---: | ---: | ---: |
| 起播首帧缺音频时钟 | 6 | 0 | 0 |
| AVC → HEVC 切换首帧最大绝对偏差 | 75.690 ms | 50.471 ms | 58.819 ms |
| AVC 分辨率切换首帧最大绝对偏差 | 75.019 ms | 52.250 ms | 50.267 ms |
| 全部已配对样本最大绝对偏差 | 75.690 ms | 52.250 ms | 58.819 ms |
| 最大跨段输出间隔超额 | 98.242 ms | 59.101 ms | 82.698 ms |

切换首帧取新 Period 的第一张实际输出画面，两类切换均在 1.5 秒。音画偏差按冻结方法将 AudioTrack 消费位置折算到视频请求释放时刻。颜色和 PTS 来自解码器输出纹理与帧元数据。该验收覆盖播放器输出和音频消费时钟；屏幕扫描与扬声器物理起声需要外部测量。[逐轮数值](evidence/2026-11-21-android-oppo-dash-av-optimization/results.json)

## 起播与切换

- **起播**。托管 DASH 有已启用的音轨时，视频渲染器在正常播放循环中等待音频 sink 首次返回有效位置，再释放第一张可见帧。等待最多 250 ms，未启用音轨时直接继续。两批中所有起播首帧都读到消费位置 0。
- **延迟音频对照**。单独将音频初始化响应体延迟 160 ms，优化前 3/3 轮首帧缺时钟，优化后 3/3 轮均已配对。相应代价是，从本地服务备好 MPD 到第一帧请求释放，三轮耗时由 124–278 ms 变为 338–372 ms。这是整段起播路径的观测值。
- **跨段**。托管、非 DRM DASH 在设备分级允许时使用 Media3 的预热渲染器。后一段可以在前一段播放时初始化解码器，接管显示 Surface 后才发布本段画面尺寸与覆盖区间。第一批六次跨编码或分辨率切换中，新解码器在切换首帧释放前 1.46–1.59 秒已初始化。受限档设备沿用单视频解码器。
- **同格式对照**。在相同的 1.5 秒边界，AVC 320×180 连续两段的三轮首帧绝对偏差，优化前为 9.028–20.636 ms，优化后为 27.557–42.102 ms。该场景也可触发预热，三轮仍在 70 ms 内。

## 回归与复核

OPPO 上 30 个公开 Flutter 用例通过，覆盖 19 个跨段播放与几何用例、2 个中途停止或替换用例、3 个视频缺口字幕像素用例，以及 6 个 DASH 播放与网络策略用例。另有 8 个原生 PCM 用例及 1 个原生生命周期用例通过，覆盖前后台回调期间的位置保存、恢复后跨段尺寸、停止和重复释放。

在公开跨段套件运行期间，针对同一应用进程采集了 112 次系统媒体资源快照。峰值为两个视频解码器，跨编码时同时观察到 AVC 和 HEVC。套件结束后连续三次采样均为零。Android JVM 测试通过 611 个，跳过 3 个。本机 JDK 21 通过临时 Gradle init 脚本为测试进程开启 Byte Buddy 兼容选项。[原始日志、回执与资源样本](evidence/2026-11-21-android-oppo-dash-av-optimization/captures.tar.xz)

原生包和各 Flutter 测试包均核对了构建与安装的 SHA-256。解压归档后，在仓库根目录对 `final/samples.log` 及 `repeat/samples.log` 分别运行下列命令，即可独立复算每批严格验收。对照组的两种素材单列在 `controls/samples.log`。此结论适用于上述手机与冻结素材。

```sh
python3 -B tool/dash_timeline/joint_observations.py final/samples.log --platform android --limits tool/dash_timeline/joint_acceptance.json --output metrics.json
python3 -B tool/dash_timeline/joint_timing.py final/samples.log
```
