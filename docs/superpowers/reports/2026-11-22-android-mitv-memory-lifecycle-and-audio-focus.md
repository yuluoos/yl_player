# 小米电视双会话低内存恢复与系统音频焦点验收

小米 MiTV-MTTP0（Android 9 / API 28，32 位 ARM）在同一低内存组合场景连续通过两轮。两轮复用同一安装包，逐次核对电视上的 APK 哈希。此前的 20 分钟本地长播已推进到 1,201.107 秒，结束时掉帧和音频欠载均为 0。[长播报告](2026-11-21-android-mitv-api28.md)

## 双会话与内存压力

两个公开播放器分别加载同一份 HTTP Range AVC/AAC 素材。先暂停第一个，再启动第二个。主机向应用发送 Android 的前台内存压力回调，并用 HOME 和重新打开同一个 Activity 验证恢复。采集器按应用 PID 查询系统视频解码器计数和 PSS，并从每个会话的 Media3 分配器读取实际缓冲占用。

| 观测项 | 第一轮 | 第二轮 |
| --- | --- | --- |
| 运行前 / 压力下 / 恢复后，活动会话缓冲目标（MiB） | 24 / 18 / 24 | 24 / 18 / 24 |
| 系统成功投递的前台压力等级 | 16 | 16 |
| 压力下的缓冲实际占用，原会话 / 活动会话（KiB） | 0 / 4224 | 0 / 5184 |
| 回前台重新初始化的解码器 | OMX.MS.AVC.Decoder | OMX.MS.AVC.Decoder |
| 停止两会话后的系统解码器计数 | 0（4 次采样） | 0（4 次采样） |
| 各阶段进程 PSS 采样范围（MiB） | 162.5–250.9 | 170.9–262.5 |

回后台后，活动会话暂停，三秒内位置保持稳定，系统观察到视频解码器降为 0。回到前台后，同一会话重新取得解码器，原生首帧回调指向该会话当前的公开 Surface。两个会话 ID 均保留。停止第二个后，它的旧指令收到 session.stale；第一个可以从 4 秒处重新播放。全程采样最多 1 个视频解码器。

修复前，从主屏幕返回播放器时两个会话都尝试重新取得独占解码器，原先暂停的会话变成 failed。现在已让出解码器的会话推迟前台恢复，直到收到播放请求。主机单测还覆盖先通知当前会话、再通知原会话的顺序。首轮诊断记录了 RUNNING_CRITICAL 成功投递及活动预算从 24 MiB 降至 18 MiB；最终两轮的投递等级见表。早期试跑还校正了对非活动会话的判定：它已归还全部分配块，压力下读取其实际占用为 0。

本轮验证了进程存活时的系统内存回调、前后台恢复与资源归还。Android API 24 的最低版本验证仍单列。

## 系统音频焦点

播放器和竞争进程分别使用 UID 10043、10041。在同一内置扬声器路由上，两轮各通过 6/6：短暂中断恢复、超过三秒宽限期的中断恢复、可压低音量的中断按播放器策略暂停、永久抢占后手动重播、用户暂停阻止自动恢复，以及应用管理焦点时继续播放。每轮五个需要暂停的场景中，从公开 paused 状态到持有期结束的位置差均为 0 ms。测试结束后，两个进程都已退出系统焦点栈。

修复前，两次冷启动首次暂失焦点后的进度分别多走 205 ms 和 232 ms。播放器现在等待 Media3 播放线程处理暂停，再发布位置，并丢弃后续播放命令已经替代的旧暂停通知。电视当时枚举到的音频输出只有内置扬声器，蓝牙和外接设备切换仍待验证。

## 复测与证据

低内存测试入口为 example 的 android_memory_lifecycle_test.dart。依次在 YL_MEMORY_PHASE 的 trim、background、foreground 标记发送 adb shell am send-trim-memory dev.ylplayer.yl_player_example RUNNING_CRITICAL、adb shell input keyevent KEYCODE_HOME、adb shell am start -n dev.ylplayer.yl_player_example/.MainActivity。若系统已处于 CRITICAL（15）而拒绝重复通知，则发送数值 16，仍低于触发后台释放的 UI_HIDDEN（20）；两次 shell 调用分别留存回执。同步使用 dumpsys media.resource_manager 和 dumpsys meminfo 按 PID 采样。

焦点测试入口为 android_audio_focus_peer_test.dart。先构建并安装 :yl_player_android:assembleDebugAndroidTest 生成的测试 APK。播放器输出 YL_AUDIO_FOCUS_PEER 的本轮端口和令牌后，在电视上运行：

```sh
adb -s "$serial" shell am instrument -w -e focusPort "$port" -e focusToken "$token" \
  -e class dev.ylplayer.yl_player_android.YlAudioFocusPeerInstrumentedTest \
  dev.ylplayer.yl_player_android.test/androidx.test.runner.AndroidJUnitRunner
```

Android JVM 回归共 645 项，跳过 3 项，失败和错误均为 0。两份 Dart 集成测试通过静态分析。汇总包含各组测试 APK、归档成员和源码 SHA-256。每个测试入口单独构建 APK。[结果汇总](evidence/2026-11-22-android-mitv-memory-lifecycle-and-audio-focus/results.json) · [设备回执、前后对照及逐阶段采样](evidence/2026-11-22-android-mitv-memory-lifecycle-and-audio-focus/captures.tar.xz)

结果汇总 SHA-256 为 `68dc806477c376fee3c1159258f6704713a2863db365cfd31b007c6ec0fe1528`。原始采集归档 SHA-256 为 `99c4cb0f4f99cdfa86a2af6fdae8f200d581da0320c4a7cf04728002902cd9e9`。
