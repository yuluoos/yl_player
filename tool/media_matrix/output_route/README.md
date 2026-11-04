# macOS 真实音频端点测试

使用包含 Core Audio 进程属性的 macOS SDK 编译探针。在解锁的桌面上连接耳机或 USB 音频设备，从设备列表选择原默认输出与另一物理端点。测试会在运行时切换系统默认播放设备，并在退出时恢复。

```sh
clang -fobjc-arc -framework Foundation -framework CoreAudio tool/media_matrix/output_route/probe.m -o /tmp/yl-route-probe
/tmp/yl-route-probe list
```

以 example 的 `integration_test/macos_output_route.dart` 为 Flutter 构建目标。报告中的原 SDK 对照使用 Profile AOT 前端及 `package_macos_matrix.py` 绑定矩阵的 Swift 与 codec 映像。给采集器传入实际 app、探针、未使用的结果目录和设备列表中的两个 ID。

```sh
python3 -B tool/media_matrix/output_route/run.py APP /tmp/yl-route-probe OUT --devices ID1 ID2 --mode same-session
python3 -B tool/media_matrix/output_route/run.py APP /tmp/yl-route-probe OUT2 --devices ID1 ID2 --mode explicit-reload
python3 -B tool/media_matrix/output_route/run.py APP /tmp/yl-route-probe OUT3 --devices ID1 ID2 --mode failure-reload
```

`same-session` 要求同一会话在新端点持续播放。`explicit-reload` 在 HAL 显示旧输出停止后，通过测试进程的标准输入请求调用方显式重载。每轮会记录端点、PID 的实际输出和公共媒体时间，最后等待自然结束。默认音量由应用自身设为 15%。

修复验收使用 `failure-reload`。仅在原会话进入 `failed`、错误码为 `render.audio_engine_failed` 且进程已停止输出后才请求显式重载。
