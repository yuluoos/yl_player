# OPPO 九份替代脚本行为兼容验收

2026-11-21，OPPO CPH2065（Android 12 / API 31，arm64）正式批次 **9/9 通过**。九份独立编写的替代脚本按历史行为表使用相同的裸查询参数。每份在设备上的原生 QuickJS 显式解析两次，均返回有效期未知的结果；第二次返回的 URL 和请求头直接交给公开播放器。九次均由 Media3 从手机回环服务读取 HLS，取得匹配会话的首帧和有效画面尺寸。版本基线为 `8a27caa9`，本次仅新增测试、证据及调整共享测试响应。[历史行为表](2026-09-26-remaining-05-live-business.md) · [替代脚本](../../../packages/yl_player_source_resolver/test/support/substitute_scripts.dart) · [真机测试入口](../../../packages/yl_player_source_resolver/example/integration_test/substitute_behavior_test.dart)

| 对应编号 | 本机核验的差异行为 | 结果 |
| --- | --- | --- |
| JS-01 | 从 GET 响应的嵌套数组取出视频地址；响应同时含有效地址和错误时，公开解析返回 `script.reported_error`。 | 通过 |
| JS-02 | `parseItems` 读取频道；按请求中的十位时间戳独立生成密文，脚本用 CryptoJS AES-CBC/PKCS7 解密出本轮 HLS 地址。 | 通过 |
| JS-03 | 相符的 Host 可发送；传入错误 authority 时解析失败且回环服务器未收到请求。 | 通过 |
| JS-04 | `mytv.fetch` 读取 JSON 的 `stream_url` 并播放。 | 通过 |
| JS-05 | `parseItems`、`resultSet[].url` 和频道请求头；媒体服务实收并核对该头 6 次。 | 通过 |
| JS-06 | 实收 POST 正文恰为两个 UTF-8 字节 `{}`；脚本跳过首个干扰频道，按目标 ID 选取地址。 | 通过 |
| JS-07 | `parseItems`、受控签名模板、八位十六进制时间字段；由 Dart 独立复算签名。两条同值 Referer 归一，媒体服务实收并核对 6 次。 | 通过 |
| JS-08 | `mytv.fetch` 读取频道列表，跳过首个干扰频道，按 Id 选取 `PlayStreamUrl`。 | 通过 |
| JS-09 | 两次本地签名均在拦截所有宿主 HTTP 请求的条件下完成，调用数为零；独立核验 `auth_key` 的四段结构和测试摘要。 | 通过 |

## 取消、失败与停止

八份联网脚本各在真实回环 HTTP 请求已到达、响应仍挂起时取消。八次均收到 `script.cancelled`，服务端均观察到连接关闭。另对每份联网脚本单独注入一次传输异常，八次均得到 host 阶段的 `script.execution`，随后同一解析器成功复用。JS-09 验证立即取消及再次使用。每份播放停止后，当前会话清空，200 ms 观察窗内无迟到首帧。套件结束后，测试进程仍在，针对该 PID 的三次系统资源采样均显示音频和视频编解码器占用为零。[逐项计数与源码哈希](evidence/2026-11-21-android-oppo-substitute-script-behavior/results.json)

## 证据与复测

正式结果取归档中的 `verified` 批次。另两批调试运行各通过相同九项，分别保存测试入口和 APK 回执。每批均核对已安装 APK 与本地构建的 SHA-256。每项同时记录替代脚本模板哈希及绑定本轮回环地址后的实际执行文本哈希。Flutter 终态计数包含框架收尾，表中只计九个有独立回执的行为用例。[设备日志与安装回执](evidence/2026-11-21-android-oppo-substitute-script-behavior/captures.tar.xz)

在 resolver 示例目录中，可用 `flutter test integration_test/substitute_behavior_test.dart -d <设备ID>` 复测。此项验收覆盖自有脚本、受控响应和真实安卓播放。原始 JS-01～JS-09 在本机本轮仍为 0/9；原版逐字节兼容性及原线上服务的可用性各自保留原有状态。[原始归档预检](2026-11-21-android-oppo-av-dns-script-followup.md)
