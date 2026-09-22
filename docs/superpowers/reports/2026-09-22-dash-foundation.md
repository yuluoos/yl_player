# DASH 基础接入实施记录

状态：本批实现与验证完成；DASH 集成 6/6、相邻会话替换 3/3 通过，最终独立整体复审通过，无阻塞项。完整需求以[需求基线](../specs/2026-09-20-playback-expansion-requirements.md)为准。

## 本批实现

- 公共 `YlMediaFormat.dash` 追加为 ordinal 10，保留已有 0–9；Android/Apple 的生成桥接和 codec 同步更新。
- Android 使用现有版本 Media3 1.11.0 DASH 模块，接入明文 static MPD、显式无扩展名与自动 `.mpd` 路由；维持受控 HTTP、凭据继承和重试策略。
- MPD BaseURL 祖先与 init/index/media URI 在请求前登记，同源保留凭据，跨域及返回原域继续剥离。解析资源限制与当前拒绝项见[平台支持](../../platform-support.md)。
- DASH 失败不再交给不能处理 MPD 的 FFmpeg 回退；其他格式的恢复策略保留。
- Apple 当前明确拒绝显式 DASH 和 `.mpd`，严格策略返回相应策略错误，不误入 Matroska 回退。
- 私有 schema 升至 3，公共 SPI 仍为 2；旧 schema 1/2 在 Create 握手时拒绝，且不泄漏资源。混用新旧 Dart/native 需要完整重建，见[兼容说明](../../transport-compatibility.md)。
- 明确错误的固定安全文案在 Dart 层按可信错误码映射，原始原生异常不透传；未知码保持通用文案。
- 新增自制 8 秒、两个 4 秒 Period 的 H.264/AAC fMP4 夹具、生成脚本、逐文件 SHA256 和双本地 HTTP 源测试服务；无第三方媒体下载。

## 已执行的验证

| 验证 | 当前证据 |
|---|---|
| Dart interface/Android/Apple | 最终根目录 `flutter test packages/yl_player/test packages/yl_player_android/test packages/yl_player_apple/test packages/yl_player_platform_interface/test`：323 项通过（包含本批公开安全文案） |
| 公共控制器消费者 | `flutter test packages/yl_player/test`：69 项通过 |
| macOS 原生路由及注册 | `YlEngineAssessmentTests` + `YlAppleRegistryTests`：8 项通过、0 失败、0 跳过；XCResult 已核实 |
| iOS 原生路由及注册 | 同上，iPhone 18 Pro / iOS 27 模拟器：8 项通过、0 失败、0 跳过；XCResult 已核实 |
| Android JVM | 停止修复后完整 324 项通过，0 失败/错误（JDK 17）；随后加强的清理契约用例定向 52 项通过 |
| Android 实际播放 | API 36 / Android 16 / emulator-5554：6/6 通过，覆盖显式与自动首帧、跨 Period seek/继续播放至完成、3 种凭据路径、明确安全的 403 错误、活动及待加载停止 |
| 相邻 Android 会话回归 | `android_session_replacement_test.dart`：3/3 通过；包含实际回调确认、新加载取消旧加载、私有候选画面与公开输出隔离 |
| Pigeon | 二次生成 4 个输出哈希一致 |
| Apple 夹具 | 当前源码库存 454 iOS / 370 macOS，当前镜像及历史来源检查通过；库存数不是全量运行数 |

实际设备命令（在 `packages/yl_player/example`）：

```sh
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home YL_ANDROID_DEVICE_ID=emulator-5554 sh ../../../tool/run_android_integration.sh integration_test/android_dash_playback_test.dart
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home YL_ANDROID_DEVICE_ID=emulator-5554 sh ../../../tool/run_android_integration.sh integration_test/android_session_replacement_test.dart
```

合成 MPD SHA-256：`9ed58044accfc270c83f08708fa227ddc12de96b77e8e63b6c061e0e6128ce9a`；23 项媒体/清单文件校验通过。同一 FFmpeg 8.0.1 工具链重复生成哈希一致。改动的 Dart 静态分析无问题；`git diff --check` 通过。

旧 schema 接受错误、自动 DASH 路由、真实 Media3 parser 凭据登记、动态 MPD 拒绝、无效 FFmpeg 回退均先观察到行为失败，再修复。首轮 Apple 测试错选类名执行 0 项，已作废并改用实际类名重新观察失败。Android 首轮集成构建成功后因素材子目录未打包而未进入播放断言，此结果不作播放证据。

独立审查发现长 BaseURL × 有限分段数仍可能放大地址内存，修复增加每 URI 8,192 UTF-16 单元及每次解析 4,194,304 单元的保守累计预算，并提前限制模板替换与数字填充。该修复已复审通过。设备测试另暴露 Stop 的清理任务自取消问题，已修复并通过复审及实际设备用例：清理任务不再取消自身确认，所有借用者释放完成前保留输出，再传播真实清理错误。

相邻回归曾因仅用于 debug 的反射探针把 ManagedAndroidEngine 包装层误当 Media3 实例而报字段不存在；现只对该已知包装类型解包 current 实例，不改生产接口、不弱化画面断言。修复后旧会话替换文件 3/3 通过，且实际私有/公开 Surface ID 不同，日志 `/var/folders/7k/p9cms6417rlfqrpv2_6hs1900000gn/T/yl-android-test.FA8jCT`。

最终 DASH 6/6 运行日志：`/var/folders/7k/p9cms6417rlfqrpv2_6hs1900000gn/T/yl-android-test.EVKkZm`。公共程序时间轴允许 2 毫秒容器时间基误差（实际 7.999 秒），跳转到 5 秒后必须继续超过 5.5 秒并播放完成。挂起首段的取消测试保留 pending Load，停止后必须得到 `load.cancelled` 且无迟到事件；不等待就绪后再测试取消。

Xcode 输出仍有既有 Swift 并发/弃用及测试框架部署版本警告，相关 XCResult 的 runtimeWarnings 为空。测试只覆盖当前模拟器及主机，不代表最低 OS 或真机矩阵。

## 复审结果

核心格式/路由与私有握手、URI 资源限制、停止清理契约、公开安全文案分别经独立审查。最终整体审查核对跨组件集成与调试观察器，判定本阶段符合范围且代码质量通过，无阻塞项。测试由实现阶段执行，审查没有重复运行已通过套件。

## 尚未完成的范围

Apple DASH 播放、字幕与完整 ABR/手动清晰度矩阵、受保护 DASH、DRM 许可证与安全显示、JS 直播解析、RTMP、完整杜比映射及性能共同验收仍待后续实施。用户当前无授权 DRM 流/许可证服务；PD-01/02/03 尚未决定，本批不替其作产品决策。不接入商业 SDK。

## 本批工程决定

沿用当前功能分支并保留上批未提交改动，避免重建工作区丢失上下文；代价是独立交付时需另行整理提交。私有协议升至 schema 3 以避免旧原生解码新增枚举时崩溃；代价是即使使用旧格式，新旧二进制也不能混用。设备验收驱动追加了最小 Stop 清理契约修复，代价是触及共享清理路径，已补充非 DASH 与失败借用者回归。公开已知错误改用固定安全文案，代价是对应消息文本变化，稳定错误码保持不变。相邻失败门槛中的旧 debug 观察器按当前已知包装结构修复，代价是测试探针仍依赖内部结构，后续结构变化需同步维护。所有变更未提交、未发布。
