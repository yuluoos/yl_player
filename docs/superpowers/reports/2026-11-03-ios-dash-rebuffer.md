# iOS DASH 点播在 25 秒停流后的续播

iPhone 16，iOS 27.2（24B119）。对照组为 main `767eead4`，修复组仅修改 AVPlayer 缓冲等待期限。两组使用同一台设备、120 秒 DASH 素材、公开原生播放会话和相同的[网络曲线](evidence/2026-11-03-ios-dash-rebuffer/profile.json)。服务端在第 10–15 秒及第 50–75 秒暂停发送媒体正文，恢复后正常传输。两组均使用生产自动画质恢复策略。

| 观测 | 修复前 | 修复后 |
| --- | --- | --- |
| 25 秒停流期间 | 媒体项仍就绪，时间轴停在 58.913 秒。首次缓冲超时后公开会话进入 failed | 保持原会话和播放意图。媒体到达后继续发布帧 |
| 停流两侧的帧 | 会话结束前未恢复 | 59.875000 秒 → 59.916667 秒，两帧提交间隔 16.475 秒，同一媒体项 |
| 终态 | 原生测试退出 65，未播完 | 原生测试退出 0，自然结束于 120.023 秒，零会话失败 |
| 恢复后的画质 | 低档 | 生产策略在同一会话提交一次恢复，之后有 640 像素宽新帧 |

原逻辑用一次读取超时同时决定 AVPlayer 的整次缓冲是否失败。本次调整将已经出过首帧、媒体项仍就绪的 iOS DASH 点播等待期限设为 `readTimeout × (1 + maxRetries)`，默认 60 秒。AVPlayer 持续使用原媒体项和时间轴。用户暂停或停止仍会撤销等待，缓冲窗口耗尽仍走原有失败路径。真机相邻回归覆盖用户暂停、停止、首帧原始期限及点播／禁用重试的终止行为，4 项通过。

## 回放验证

[修复前采集](evidence/2026-11-03-ios-dash-rebuffer/before.tar.gz)和[修复后采集](evidence/2026-11-03-ios-dash-rebuffer/after.tar.gz)分别保存原始回执、服务端请求、播放状态、新帧和系统中断记录。将两份归档解压到独立目录后，从仓库根目录运行以下命令。修复前退出 1，修复后退出 0。

```sh
python3 -B tool/playback_network/verify_stall_resume.py <解压后的采集目录>
```

在已配对的 iPhone 上使用当前签名测试构建，可用既有采集入口重现这条曲线。

```sh
python3 -B tool/playback_network/abr_accesslog.py \
  --products "$TEST_PRODUCTS" --directory "$NEW_CAPTURE" \
  --physical-device "$IPHONE_UDID" --owned-host "$MAC_LAN_IP" \
  --duration-seconds 120 --recovery-action auto-reload --production-recovery \
  --profiles docs/superpowers/reports/evidence/2026-11-03-ios-dash-rebuffer/profile.json \
  --profile downshift-and-25s-body-stall-v1
python3 -B tool/playback_network/verify_stall_resume.py "$NEW_CAPTURE"
```

## 验收范围

修复后原始综合回执仍为 `passed=false`。393 个代理请求中有 9 个上游失败请求未匹配服务端记录。播放续播判定只验证故障时段确实无媒体正文、超出一次读取期限后同一会话继续发布相邻帧、最终自然结束及测试宿主退出。历史无线链路约 25 秒无入站包的成因仍待 AP 侧证据，本次重现的是相同量级的媒体中断。

修复前另有一轮短停流真机控制，到 120.029 秒自然结束，但未达到自动升档门槛，依赖升档触发的第二次故障没有执行。模拟器首次画质矩阵被外层限时终止，热启动补测播完；限档及固定阶段仅观察到 320 宽新帧，但初始自动阶段未观察到 640 宽，完整模拟器回执未通过。

最终签名构建另在同一 iPhone 上通过公开画质策略五阶段测试。首次自动、解除上限和恢复自动均发布了 640 宽新帧；限档阶段的 367 个新帧和固定阶段的 461 个新帧全部为 320 宽。全程同一会话，自然结束于 120.055 秒，该轮综合回执通过。[真机画质和相邻回归结果](evidence/2026-11-03-ios-dash-rebuffer/physical-policy.json)
