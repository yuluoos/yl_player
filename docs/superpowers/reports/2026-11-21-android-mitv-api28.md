# 小米电视 Android 9 播放验收

设备为 Xiaomi MiTV-MTTP0，MStar m7332，Android 9 / API 28，32 位 armeabi-v7a。系统报告总内存 1,362,636 KiB，应用堆增长上限 192 MiB，显示分辨率 1920 × 1080。测试基于 `9bf8301d`，APK 增加了验收入口和只读调试观测。播放器采用默认解码策略。[设备回执](evidence/2026-11-21-android-mitv-api28/identity.json)

## AV1 本地与 HTTP 严格验收

同一份 armeabi-v7a Debug APK 串行运行仓库的 `run_bound_flutter_android.py`，以项目的 AV1/Opus MKV 样片通过两格严格验收。两次均核对了已安装 APK、样片和会话身份，观察首帧、自然播放完成、跳转至 1.25 秒、2.25 秒和 0 秒，以及音频输出关闭和播放器释放。严格用例记录的实际视频解码器为 `OMX.MS.AV1.Decoder`，音频为 `OMX.google.opus.decoder`；API 28 对视频解码器的硬件属性报告 `UNKNOWN`。[本地验收](evidence/2026-11-21-android-mitv-api28/strict-file.json) · [受管 HTTP 验收](evidence/2026-11-21-android-mitv-api28/strict-http.json)

| 输入 | 播放 / 三次跳转的像素样本数 | PCM 窗口数 | 严格验收器 |
| --- | --- | ---: | --- |
| 本地文件 | 49 / 15 / 13 / 13 | 7 | 通过 |
| 受管 HTTP | 50 / 13 / 15 / 14 | 7 | 通过，6 个请求交付 282,453 字节，拒绝 0 个 |

像素来自 Flutter 画面，音频来自同次播放的 AudioTrack 播放头和 PCM。离线解压 ADB 原始回执，重放仓库原校验器，两次均为 `scopeAcceptance=true`，错误列表为空。[本地原始记录](evidence/2026-11-21-android-mitv-api28/strict-file-rows.jsonl.xz) · [HTTP 原始记录](evidence/2026-11-21-android-mitv-api28/strict-http-rows.jsonl.xz)

**Android 格式跨设备、跨构建累计 40/40**，本地和受管 HTTP 各 20/20。以用例、传输方式和样片哈希核对，OPPO 已严格通过的 38 格与小米电视新增的两格正好覆盖所有必测项。OPPO 同机同包仍是 38/40，小米电视本次定向跑了这两格。另用普通公开播放器验证了设备内 HTTP 和经局域网 ADB 转发的主机 HTTP/1.1，AV1 两条路径均能跳转及播放至结束。主机首轮 HTTP/1.0 出现过连接提前关闭，本次 HTTP 证据限于受控服务。[跨设备逐格记录](evidence/2026-11-21-android-mitv-api28/cross-device-coverage.json) · [主机 HTTP 复测](evidence/2026-11-21-android-mitv-api28/http-av1.json)

## HEVC 回退解码器换 Surface

原生回归以 `-e ylSurfacePolicy device` 运行。生产判断在这台设备上两次识别了 `OMX.MS.HEVC.Decoder`。每次只重建一次 Surface，测试从替换后的 SurfaceTexture 实际读到画面，并核对解码时间戳。两条路径使用同一 MOV 样片。顺序模式通过测试接口让 demux seek 返回失败，覆盖真实解码器等待下一关键帧的分支。[JUnit 回执](evidence/2026-11-21-android-mitv-api28/native-junit.txt) · [设备日志](evidence/2026-11-21-android-mitv-api28/native-log.txt)

| 操作 | 换面时的位置 | 观测到的恢复帧 PTS | 结果 |
| --- | ---: | ---: | --- |
| 暂停可跳转文件，换面后继续 | 360.000 ms | 416.667 ms | 暂停期间画面保持，恢复后有新帧 |
| 播放中换面，模拟源只允许向前读取 | 514.619 ms | 1,000.000 ms | 下一关键帧恢复 |

两项都执行了释放，JUnit 报告 2/2。系统媒体资源服务随后记录该测试进程持有 0 个视频解码器。APK 安装后哈希与构建产物一致。[构建回执](evidence/2026-11-21-android-mitv-api28/native-receipt.json) · [系统资源回执](evidence/2026-11-21-android-mitv-api28/native-release.json)

## 低内存 32 位电视的 20 分钟长播

使用同一个公开 Flutter 会话，以 1× 连续播放本地 320 × 180、24 fps 的 AVC/AAC MKV。20 个逐分钟采样点都处于播放状态，Media3 均报告隧道已启用。最后媒体位置为 1,201.107 秒，累计渲染 28,835 帧。重缓冲累计值在第 1 分钟为 1，到第 20 分钟仍为 1；全程结束时掉帧和音频欠载累计值均为 0。[逐分钟回执与资源采样](evidence/2026-11-21-android-mitv-api28/first.json)

Android 拒绝了对测试进程发送的 `RUNNING_LOW` 通知，随后的进程回执显示系统已将其置于更高的 `trimMemoryLevel=15`。第 1 分钟以后的活跃期 PSS 样本为 154,173 至 162,305 KiB，释放后为 157,511 KiB。同一 PID 播放时持有一个视频解码器，释放后为零。以上数字适用于这段低分辨率样片和 Debug 构建。

## 隧道、倍速和恢复

在公开播放器的同一个会话里，从 Media3 工作线程分别读取轨道选择器的隧道请求和 ExoPlayer 的实际隧道状态。下表是同一次复测的两种输入。实际倍速取媒体位置增量除以窗口的单调时钟时长。[会话、解码器与逐阶段回执](evidence/2026-11-21-android-mitv-api28/repeat.json)

| 操作 | 隧道请求 / 实际 | 本地实际倍速 | 受管 HTTP 实际倍速 |
| --- | --- | ---: | ---: |
| 1×，10 秒 | 开 / 开 | 0.96× | 0.96× |
| 切至 1.5×，前 12 秒 | 关 / 关 | 0.73× | 0.70× |
| 保持 1.5×，后 12 秒 | 关 / 关 | 0.81× | 0.81× |
| 切回 1×，10 秒 | 开 / 开 | 0.36× | 0.40× |

两个 1.5× 窗口结束时，本地累计掉帧 323、音频欠载 198 次；受管 HTTP 累计掉帧 318、音频欠载 189 次。切回 1× 时隧道确实恢复，但 10 秒末两边都仍在缓冲，发出暂停命令后又等了 12 秒，公开状态仍为 `buffering`。首轮本地播放同时记录到 79,288 ms 已缓冲媒体和持续增加的欠载。这台电视上可以用本地文件复现，诊断应优先检查退出隧道后的音频输出与时钟，以及重新进入隧道时的缓冲恢复。[首轮播放器诊断](evidence/2026-11-21-android-mitv-api28/first.json)

另取主机经局域网 ADB 转发的 HTTP/1.1 Range 服务复测。1.5× 两个窗口实际分别为 0.73×、0.80×。切回 1× 并暂停后，位置停在 32.246 秒，公开状态仍为缓冲。此时跳至 90 秒成功；卸载视图后实际退出隧道，重新挂载后再次进入，收到两次匹配当前公开 Surface 的首帧回调，媒体位置推进至 97.166 秒。最终视频解码器持有数为 0。画面证据来自渲染器与当前输出 Surface 的匹配，物理面板黑屏或扬声器听感仍需现场观察。[主机 HTTP 及重挂回执](evidence/2026-11-21-android-mitv-api28/http-speed.json)

在独立 1× 对照会话中，暂停成功，位置保持在 10.192 秒；随后跳至 90 秒、卸载再挂载视图，隧道依次关闭和重新启用。重新挂载后收到两个匹配当前公开 Surface 的首帧回调，恢复播放至 96.999 秒，累计掉帧 0、音频欠载 0。Flutter 完整用例通过，释放后该 PID 持有 0 个视频解码器。此前的暂停状态异常可在倍速往返后复现。[独立生命周期回执](evidence/2026-11-21-android-mitv-api28/lifecycle.json)

## 复跑范围

普通公开播放器入口为 `integration_test/android_tv_playback_test.dart`。在本项目示例的 32 位 Android Debug 构建中，使用 Dart define `YL_TV_CASE` 选择 `av1-file`、`av1-http`、`speed-file`、`speed-http`、`lifecycle` 或 `continuous`。`YL_TV_HTTP_BASE` 可指定能按字节范围返回相同样片的受控主机服务，缺省使用设备内的受管 HTTP 服务。严格格式采集使用独立入口 `integration_test/bound_av_test.dart` 和构建开关 `ylBoundAV=true`。本轮覆盖 API 28；最低系统 API 24 的同机复测及正式性能基线仍需分别取证。
