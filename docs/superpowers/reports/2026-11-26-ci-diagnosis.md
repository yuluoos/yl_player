# Android API 24 与托管 iOS 失败诊断摘要

本次诊断针对提交 `1459a89054e6db225f656df8d74a2eba0b46e769`。

Android API 24 的 x86_64 模拟器运行了 11 项用例。纯音频播放和严格硬解拒绝两项通过。其余 9 项均在视频加载时返回 `decoder.unavailable`。镜像只声明了软件 AVC 解码器。这些正向用例仍需在具备合格 AVC 解码路径的 API 24 真机上验证。[CI #170](https://github.com/yuluoos/yl_player/actions/runs/45464214343) · [CI #171](https://github.com/yuluoos/yl_player/actions/runs/45670127465)

CI #170 的 iOS 模拟器运行 904 项 XCTest，870 项通过、33 项失败、1 项跳过。同一组 33 个测试标识在本地模拟器均复现 `decoder.unavailable`，在 iPhone 16 上全部通过。独立 H.264 探针在模拟器上强制启用硬解时，两次均返回 `-12906`。CI #171 的托管 iOS 作业因 runner 容量不足取消。[CI #170 iOS 作业](https://github.com/yuluoos/yl_player/actions/runs/45464214343/job/138707564019) · [CI #171 iOS 作业](https://github.com/yuluoos/yl_player/actions/runs/45670127465/job/139414325007)
