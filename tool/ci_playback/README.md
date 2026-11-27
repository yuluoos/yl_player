# 播放 CI 的模拟器与真机分片

`cases.json` 登记了 iOS 与 Android API 24 的 Flutter 用例和必须上真机的 iOS XCTest 标识。iOS Simulator 跑原生规范清单的补集，iOS 真机跑显式列出的 34 项，包括需要实际 H.264 输出的 R19 用例。两个分片都用原有 XCTest 回执检查器核对实际执行标识。真机要求零跳过。

Android API 24 模拟器跑音频生命周期与严格策略拒绝用例，API 24 真机跑 9 项视频正向用例。API 36 模拟器继续跑原有套件。iOS 的 `both` 用例在模拟器可验证严格策略拒绝，在真机必须实际提交硬解会话并渲染。Flutter 分片会核验用例名称、总数和结果。已有套件新增或重命名用例时，请同步更新清单。

## GitHub Actions

PR 和普通 push 使用托管模拟器。定时和手动全量 CI 的发布门禁要求所有托管分片通过。要补跑真机，在默认分支手动触发 CI 时勾选 `run_physical_tests`。仓库管理员按下表设置 Actions 仓库变量并注册对应 runner。签名设备所在的 runner 组应只授权受保护默认分支上的这份工作流。

| 作业 | 自托管 runner 标签 | 仓库变量 | 主机条件 |
| --- | --- | --- | --- |
| Android API 24 真机 | `yl-android-api24` | `YL_ANDROID_API24_DEVICE_ID` 为 adb 序列号 | POSIX、Android SDK、adb、JDK 17、具备合格 AVC 解码路径的 API 24 真机 |
| iOS 真机 | `macOS` 和 `yl-ios-device` | `YL_IOS_DEVICE_ID` 为 UDID，按签名配置填写 `YL_IOS_DEVELOPMENT_TEAM` | Xcode、已配对解锁且允许调试的 iPhone、可用的开发签名与描述文件 |

手动勾选后，有设备变量的平台会运行真机分片并单独报告结果，缺少设备变量的平台会显示跳过。真机硬解验收以真机分片的实际回执为准。

## 本地复验

从仓库根目录执行，先用与 CI 相同的 Flutter 3.44.0 运行 `flutter pub get`。以下命令使用各平台原有入口，环境变量中的设备须已连接，模拟器须已启动。

```sh
YL_ANDROID_TEST_TARGET=simulator YL_ANDROID_API=24 YL_ANDROID_DEVICE_ID="$API24_EMULATOR" sh tool/check_player_v2.sh --full --stage android-device
YL_ANDROID_TEST_TARGET=physical YL_ANDROID_API=24 YL_ANDROID_DEVICE_ID="$API24_PHONE" sh tool/check_player_v2.sh --full --stage android-device
YL_IOS_TEST_TARGET=simulator YL_IOS_SIMULATOR_ID="$IOS_SIMULATOR" sh tool/check_native_ios.sh
YL_IOS_TEST_TARGET=physical YL_IOS_DEVICE_ID="$IPHONE_UDID" sh tool/check_native_ios.sh
```

整套本地 `--full` 另需指定 `YL_ANDROID_API24_DEVICE_ID`（模拟器）、`YL_ANDROID_API24_PHYSICAL_ID`、`YL_ANDROID_API36_DEVICE_ID`、`YL_IOS_SIMULATOR_ID` 和 `YL_IOS_DEVICE_ID`。单独手动运行原有 Flutter 测试文件仍注册全部用例。
