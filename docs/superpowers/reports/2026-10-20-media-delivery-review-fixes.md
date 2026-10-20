# 媒体交付四项复审修复验收

对应[修复计划](../plans/2026-10-20-media-delivery-review-fixes.md)，执行日期 2026-10-20。沿用未提交的拆分工作区；未提交、推送或发布。

## 修改结果

1. **macOS 独立交付清理。** 新增公开幂等 `YlPlayerMediaDeliveryPlugin.shutdown()`。嵌入宿主在主线程通过 `engine.valuePublished(byPlugin:)` 获取插件，先调用 `shutdown()`，再调用 `engine.shutDownEngine()`。它清理该插件的独立 owner、原生方法通道和服务注册，不影响其他 engine。iOS 继续使用 detach 回调。此 API 不替代宿主对其他播放器资源的销毁。
2. **共享请求头准入。** core 新增 `YlHttpHeaderAdmission`，旧 Apple 入口与独立 wire 共用。允许 HTAB，继续拒绝 CR/LF、其他 C0/DEL、保留头、大小写重复和未分类的敏感普通头。保留旧入口 `source.invalid_argument`、独立入口 `source.invalid` 的错误码。交付消息原有大小上限保持不变。
3. **core 可见性收口。** RTMP Message、ChunkReader、AMF、FlowControl、FlvStream，以及 `ylRtmpLimit`、HTTPResponseParser、ByteRingBuffer 恢复内部可见性。公开输入、取消、缓冲与交付契约继续可用；测试通过 `@testable` 访问内部协议实现。
4. **可选播放器适配。** Cast 核心改用 `YlCastLocalPlayer` / `YlCastLocalSession`，移除 `yl_player` 依赖。新增 `yl_player_cast_player_adapter` 桥接真实播放器和会话，保留交接回退、AirPlay、过期身份检查及调用方资源所有权。纯 DLNA 不再引入播放器或 FFmpeg。

## 接入变化

- 原 `player: player` 改为 `player: YlPlayerCastAdapter(player)`。
- 原 `handoff.session: localSession` 改为 `YlPlayerCastSessionAdapter(localSession)`。
- `loadAirPlay` / `returnToLocal` 返回最小 `YlCastLocalSession`；具体适配结果的 `.session` 提供完整播放器会话。
- macOS 主动关闭 engine 的宿主须添加上述原生 shutdown 调用，不能依赖不存在的 macOS detach 回调。完整示例见 [delivery README](../../../packages/yl_player_media_delivery/README.md)。

## 验证证据

| 检查 | 结果 |
|---|---|
| 真实 macOS engine 红绿测试 | 旧实现保持 engine 引用并执行 shutdown 后 HLS 仍可访问，测试失败；修复后双 engine 的 HTTP、真实 Dart factory/owner 通道、registry、重复关闭和隔离检查通过 |
| 请求头红绿测试 | 新增 HTAB 回归在旧独立 wire 失败；共享实现后两个真实原生入口的 95 组表驱动用例通过，凭据跨 origin 剥离且不重新恢复 |
| core 外部 API | 基线检测到 8 个内部符号泄漏；收口后先验证 `@testable` 可见，再逐个验证普通 import 指定符号不可见，全部通过 |
| core 协议和消费者 | core、delivery、Apple 三个真实 Swift 5/macOS 12 模块构建通过；公开输入契约和既有 11 项 RTMP 协议测试通过 |
| 独立 Cast 消费者 | 脱离 workspace，仅复制 Cast 和 platform_interface，实际 pub get/pub deps 不含播放器、Apple、media_core/delivery 或 adapter；全部 48 项 Cast 测试通过 |
| 适配行为 | 19 项 adapter 测试、2 项示例测试通过，覆盖真实 controller/session 交接、失败回退、过期身份及注入 provider 优先级 |
| 集中 Dart 回归 | 首轮 2,071 项通过、1 项超时；该“4096 HTTP-attempt cap bounds a repeated cache-thrashing scan”用例未改代码/超时/断言，隔离复跑约 4 秒通过，合计 2,072 项覆盖 |
| 静态检查 | 六个受影响包分析无问题；Dart 格式检查通过 |
| 示例构建 | macOS Debug 与 iOS arm64 Simulator Debug 通过 |
| 包与工具 | adapter 发布预检 0 warnings；公共 API 表面、shell 语法、diff 空白检查通过 |

集中 Dart 首轮与原生构建并行运行。唯一失败是既有 `network_matroska_test.dart` 的 30 秒测试超时，隔离复测通过；没有以扩大超时或删减请求次数规避验证。

Cast 的发布预检查退出 65，仅报告尚未提交的已跟踪文件这一项警告；本轮遵循要求保留未提交状态。没有执行发布。

## 可复现命令

```sh
python3 tool/media_delivery/run_macos_shutdown_test.py
python3 tool/media_delivery/run_header_parity_tests.py
python3 packages/yl_player_media_core/test/run_native_api_boundary.py
python3 packages/yl_player_cast/tool/check_standalone_dependencies.py
flutter test packages/yl_player_media_delivery/test packages/yl_player_cast/test packages/yl_player_cast_player_adapter/test packages/yl_player_apple/test packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_cast/example/test
```

测试需要 Flutter、Xcode 及本机网络监听权限。实际证据保存在 `/tmp/yl-shutdown-{red,green}.log`、`/tmp/yl-header-review-{red,green}.log`、`/tmp/yl-core-api-{red,green}.log`、`/tmp/yl-four-fixes-dart-tests.log`、`/tmp/yl-four-fixes-http-cap-retest.log`、`/tmp/yl-four-fixes-{macos,ios}-build.log`。

独立只读复审未发现新的 P1/P2。原有 Swift/Xcode 警告仍存在，包括 `Any??` 转换、SDK 新增 NWError 分支和测试 XCTest 的宿主最低版本警告；没有更改 iOS 15/macOS 12 部署下限。此轮不等同于实体 AirPlay/DLNA/CarPlay、最低系统设备或长时间直播验收。
