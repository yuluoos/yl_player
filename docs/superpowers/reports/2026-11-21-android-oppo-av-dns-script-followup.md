# OPPO 逐帧音画、系统 DNS 与冻结脚本复验

2026-11-21 使用 OPPO CPH2065（Android 12 / API 31，USB）复验上轮的三个缺口。播放器基于 `122010cb`，此次修改涉及验收入口、证据与清单。每个真机运行都核对了安装 APK 与构建产物的 SHA-256。[上轮报告](2026-11-21-android-oppo-dash-network-and-resolver.md) · [本轮逐项结果](evidence/2026-11-21-android-oppo-av-dns-script-followup/results.json) · [原始采样与回执](evidence/2026-11-21-android-oppo-av-dns-script-followup/captures.tar.xz)

## 逐帧音画

旧测量在读取 ImageReader 的 YUV 平面时终止。新入口把实际解码输出交给 SurfaceTexture，在独立 GPU 线程读取当前纹理的中心 RGB 和同一缓冲区的时间戳，再到播放线程配对 MediaCodec 帧元数据与 AudioTrack 消费时钟。每组结束时排空两条采样队列，再释放 Surface 和 EGL 资源。此方法观察应用输出和原生消费时钟，未使用麦克风或外部显示设备。[原生测试](../../../packages/yl_player_android/android/src/androidTest/kotlin/dev/ylplayer/yl_player_android/YlDashJointInstrumentedTest.kt) · [纹理采样](../../../packages/yl_player_android/android/src/androidTest/kotlin/dev/ylplayer/yl_player_android/YlDashSurfaceProbe.kt)

归档分别保留首版同线程采样、独立 GPU 线程采样和最终版本三个批次。下表仅统计最终版本的 5 组素材，每组 3 轮。15 轮全部完成，1,524 个输出帧样本均通过颜色校验且匹配帧元数据，1,518 个取得了消费时钟。没有时钟的样本保留为空，未用后续帧回填。

| 素材 | 输出帧样本 | 缺音频时钟 | 已配对样本最大绝对偏差（ms） |
| --- | ---: | ---: | ---: |
| manifest | 576 | 2 | 34.545 |
| independent-pto | 288 | 0 | 21.724 |
| clip-end | 252 | 2 | 19.940 |
| cross-codec | 204 | 1 | 76.193 |
| resolution | 204 | 1 | 75.873 |

严格参考门槛未通过。6 个缺时钟样本均位于节目时间零点。有配对的样本中，6 个的绝对偏差超过 70 ms，最大 76.193 ms。这 6 个样本均位于节目第 1.5 秒的新 Period 首帧，跨编码和分辨率变化各复现 3/3 次。上述偏差使用按原协议折算到帧释放时刻的消费时钟。参考门槛最初冻结于 Android 36 TV 模拟器，本轮按原值复算，不能据此推断物理扬声器与屏幕的同步误差。[原冻结限值](../../../tool/dash_timeline/joint_acceptance.json) · [原始记录汇总工具](../../../tool/dash_timeline/joint_observations.py)

## 系统 DNS

设备保持 USB 连接。验收包安装后临时关闭 Wi-Fi 与移动数据，使用保留的 `.invalid` 名称，在两条请求路径上先通过 Android 应用的系统解析器观察实际查询失败，再验证公开错误。清单路径直接访问未解析主机；分段路径先从设备回环服务成功读取清单，分段引用指向未解析主机。两项均得到 `network.dns_failed`、非空诊断 ID 和脱敏提示。随同入口运行的 RTMP 握手对照也通过。[Flutter 端到端用例](../../../packages/yl_player/example/integration_test/android_network_start_failure_test.dart)

Wi-Fi 和移动数据在 8.01 秒后均恢复到开启状态，飞行模式全程关闭。该结果覆盖无外网时的系统解析错误；没有观测在线权威 DNS 的 NXDOMAIN 响应。入口未提供 `YL_ANDROID_UNRESOLVABLE_HOST` 时，框架显式标记两个 DNS 用例为跳过。归档包含实测入口源码与网络开关前中后三组状态，实测后 Dart 格式化仅调整了排版。

## 九份冻结脚本

归档预检结果为 **0/9**，`executed=false`。本地未找到同名且 SHA-256 匹配的输入，用户确认手头没有原始归档。预检现在同时给出必需数、已校验数和逐文件结果，能区分归档不可用、归档可读但内容不全、以及全部验证通过。用受控样本运行的 17 项工具回归通过，九份原脚本的设备交接仍标记为缺少外部输入。[归档校验工具](../../../packages/yl_player_source_resolver/tool/generate_controlled_integration.py) · [冻结清单](../specs/2026-09-20-playback-expansion-intake.md)

采样归档 SHA-256 为 `53637b2441f752df1f3b4b197690caf1542619683af2c418d3996f550e2b41b6`，结果 JSON 为 `430eb9e2e2770e065bcc65a6180ec15cb488e27ed67daa2993941b5cbd0159eb`。各原始文件的 SHA-256 和三批测量的门槛结果均在结果 JSON 中。
