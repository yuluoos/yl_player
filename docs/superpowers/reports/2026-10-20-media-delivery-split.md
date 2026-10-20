# 媒体交付拆分验收记录

日期：2026-10-20。对应[设计](../specs/2026-10-20-media-delivery-split-design.md)、[实施计划](../plans/2026-10-20-media-delivery-split.md)和[迁移指南](../../media-delivery.md)。

## 结果

- 新增独立可选 `yl_player_media_delivery`，承载 HLS 转封装、滚动存储、HTTP 服务和租约；公共 Dart provider 可在没有播放器实例时准备 RTMP/RTMPS/HTTP-FLV 直播。
- 新增 `yl_player_media_core`，唯一持有 FFmpeg、HTTP/RTMP/HLS 输入及取消/缓冲原语。Apple 播放器和交付模块各自依赖 core，互不反向依赖。
- Apple 保留既有 API 和输入适配；自定义转换要求宿主显式添加交付插件。直接 HTTP/HLS AirPlay 与普通本地播放不要求交付插件。
- Cast 优先使用注入的通用 provider，保留旧播放器 SPI。调用方负责销毁注入的 provider。
- FFmpeg 构建工具、发布校验、CI 路径与测试脚本迁移完成。已接受 artifact lock、原构建 recipe 和所有 pinned inputs 保持字节不变；未重新声称或执行 FFmpeg 制品构建。
- 主示例测试源由不可变历史 fixture 适配产生；历史来源未修改，当前 iOS 818/macOS 863 个用例的来源与成员校验通过。

## 已完成验证

| 范围 | 结果 |
|---|---|
| core 原生边界 | macOS 12、iOS 15 模块编译；取消、网络配置、RTMP、缓冲释放和脱敏错误检查通过 |
| Apple 编译 | 全部 Swift 源码跨模块类型检查通过 |
| 独立 delivery | 真实 Flutter owner 通道、多个 owner、engine 隔离、拒绝保留旧资源、取消、失败和 dispose 通过；`otool -L` 确认不链接 Apple 播放器 |
| 实际直播 | 本机 HTTP-FLV → HLS，playlist/init/segment/Range/HEAD 全部拉取成功，关闭后服务不可访问；另用 AVPlayer 验证 HLS ready 与实际解码帧 |
| 原生回归 | 四种 VOD fixture、FLV validator、45 项 live store、1,000 次替换队列检查通过 |
| 视频输出租约 | HDR policy、mailbox、真实 sample buffer 和 pending/committed lease 生命周期通过；首次沙箱图形资源限制后在允许环境复验成功 |
| RTMP/AirPlay XCTest | 28 项全部覆盖通过：首轮 27 项通过，修复缺插件错误码后剩余 1 项单独复测通过 |
| Dart 回归 | delivery、cast、Apple、platform_interface、cast example 共 373 项覆盖通过；初轮 370 项通过、2 项归属断言更新后复测，随后新增 1 项缺插件提示回归通过 |
| 静态检查 | 六个受影响包无问题；最后新增错误提示单独检查，Dart 格式与公共 API 表面检查通过 |
| 真实宿主构建 | cast example macOS Debug、iOS arm64 Simulator Debug 构建通过；没有修改架构支持或签名设置 |
| FFmpeg | 3 slices、5 architectures、57 个桥接符号及 9 个负例通过；制品完整性、foreign-host 校验及污染负例通过 |
| 工具链 | 38 项直接相关工具测试；core ledger 14 cases、DASH 284 packets/8 fragments 回归通过 |
| 包归档 | core、delivery 的 `dart pub publish --dry-run` 均报告 0 warnings；未发布 |

## 复审修复

独立复审发现新 native wire 未完整保留旧通道的请求头准入规则。先添加失败回归，再恢复普通头敏感字段限制、保留头限制，以及两个字典联合的大小写重复检测。凭据仍须显式放入 credentials，供共享传输在跨 origin 跳转时剥离。修复后复审未发现剩余 P1/P2。

真实 XCTest 另发现 `airplay.delivery_unavailable` 被错误脱敏层映射为 `platform.failure`。已在原生固定错误码/文案表和 Dart 固定文案表中补齐，并验证不会暴露原始 URL 或凭据。

## 可复现入口

```sh
python3 tool/media_delivery/run_native_tests.py
python3 tool/airplay/run_module_tests.py --live-fixture
sh packages/yl_player_media_core/test/run_native_module_boundary.sh
sh tool/apple_hdr/run_tests.sh
python3 tool/consumer_fixtures/apple_flutter/main_example_tests.py
python3 packages/yl_player_media_core/tool/apple_ffmpeg/test_verify_artifact.py
sh packages/yl_player_media_core/tool/apple_ffmpeg/test_build_contract.sh
```

原生网络测试需要允许本机监听；Flutter 构建需要 SDK 缓存写权限。此轮详细本机日志包括 `/tmp/yl-delivery-split-native.log`、`/tmp/yl-delivery-standalone-live.log`、`/tmp/yl-airplay-vod-live-check.log`、`/tmp/yl-delivery-split-ios-build.log`、`/tmp/yl-delivery-split-macos-build.log`。目标 XCTest 结果位于 `/tmp/yl-delivery-split-consumers/`。

## 验收边界

未执行完整 iOS/macOS 原生用例矩阵、CocoaPods 实机宿主构建、最低系统/Intel 设备矩阵或长时间直播。模拟器构建与本机 HLS 拉取不代表实体 AirPlay/DLNA 接收端或 CarPlay 车机验收。没有新增 Google Cast、Android 转封装或转码能力。代码未提交、推送或发布。
