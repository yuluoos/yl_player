# 可选 DLNA 投屏实现计划

> 执行技能：superpowers:executing-plans；独立模块使用 superpowers:dispatching-parallel-agents 并行推进。用户已于 2026-10-20 确认设计并要求开始实现，不重复请求执行授权。

**目标：** 实现可选 `yl_player_cast`，支持 DLNA、现有 AirPlay 适配与 Apple 自定义直播交付。
**架构：** 新包依赖播放器的公开模型和可选交付接口，播放器不反向依赖投屏包。DLNA 管理发现/控制，Apple 适配器管理原生 HLS 交付资源。控制器串行化会话操作并隔离旧回调。
**技术：** Dart/Flutter、SSDP/HTTP/XML/SOAP、Swift、现有 FFmpeg/AVFoundation、Android 组播锁。
**设计：** [已确认设计](../specs/2026-10-20-optional-casting-design.md)。

## 全局约束

- Google Cast 不在范围内；DLNA 面向 Android/iOS/macOS，AirPlay 保持现有 Apple 支持。
- 现有最低系统版本和公开 AirPlay API 保持兼容。
- Android 不新增 RTMP/RTMPS/HTTP-FLV 转 HLS；未知设备格式能力不得当作支持。
- 不把本地首帧或 SOAP 命令成功宣称为远端出帧。
- 应用托管媒体禁止断开后继续播放；停止/销毁释放交付资源。
- 未明确要求不 commit、push、发布包或修改签名配置。文档使用中文。

## 复审重点

- 延迟加载/设备状态回调不得覆盖新会话；失败替换不能停掉原本地播放。
- 设备描述和 SOAP 响应存在恶意 XML、过大响应、跨地址重定向时必须受限。
- 未声明 HLS/fMP4 能力的设备不得启动昂贵直播转换。
- 媒体准备取消、播放器销毁、后台生产失败均释放资源并可观察。
- AirPlay 外部激活与 DLNA 冲突不得静默切换或销毁调用方播放器。

## 任务 1：公开协议与控制器

文件：新建 `packages/yl_player_cast/pubspec.yaml`、`lib/yl_player_cast.dart`、`lib/src/models.dart`、`lib/src/provider.dart`、`lib/src/controller.dart`、`lib/src/airplay.dart`、`test/controller_test.dart`；修改根 workspace。

接口：`YlCastDevice`（id/providerId/name）、`YlCastRequest`（uri/contentType/isLive/title/startPosition）、`YlCastAssessment`（supported/unknown/unsupported 与稳定 reason）、`YlCastCapabilities`、`YlCastPlaybackState`。
`YlCastProvider` 提供 id/discovery/startDiscovery/stopDiscovery/assess/connect/dispose；`YlCastRemoteSession` 提供 device/capabilities/state/load/play/pause/stop/seek/setVolume/setMuted/disconnect/dispose。
`YlCastController` 接收 providers 与可选 player，提供设备发现、源评估、cast、远端控制、返回本地、AirPlay 加载与 dispose。

- [x] 编写能力拒绝、串行命令、失败加载保留本地、迟到事件、托管媒体禁止 detach 和 AirPlay 冲突测试，并记录失败。
- [x] 实现公共模型与最小控制器，直接媒体与需要 Apple 交付的源分开评估。
- [x] 接入 AirPlay 系统选择器适配，保持既有 API。
- [x] 运行新包测试和静态分析。

## 任务 2：DLNA 设备发现和远端会话

文件：`lib/src/dlna/{provider,discovery,description,transport,session}.dart` 和 `test/dlna_*_test.dart`，均位于新包。
接口：任务 1 的 provider/session 模型；`YlDlnaProvider` 默认生产网络实现，允许测试注入 SSDP 地址和描述 URL。

- [x] 用真实回环 UDP/HTTP peer 写 discovery 去重/过期/取消、SOAP fault/状态/音量/seek/格式能力测试。
- [x] 实现有界 SSDP、设备描述/SCPD/ConnectionManager 能力读取、SOAP 控制及会话状态轮询。
- [x] 响应最多 1 MiB、XML 深度最多 32、请求超时 5 秒、扫描窗口默认 5 秒、设备最多 128；禁用 XML DTD/实体与自动 HTTP 重定向。
- [x] 实现设备失效、取消、dispose 清理；通过测试。

## 任务 3：Apple 交付资源（可与任务 2 并行）

文件：platform_interface 新建 `lib/src/platform/media_delivery.dart`；核心 controller 与导出；Apple Dart 适配/消息通道及 Swift 交付资源管理；对应 Dart/native 测试。
接口：`YlMediaDeliveryPreparation` 提供 `Future<YlMediaDeliveryLease> result`、`Future<void> cancel()`；`YlMediaDeliveryLease` 提供 uri/contentType/isLive、`ValueListenable<YlMediaDeliveryState> state`、dispose；状态 ready/failed/closed 与可选 YlFailure。
可选 SPI：`YlMediaDeliveryPlatformPlayer.prepareMediaDelivery(YlMediaSource source, {YlLoadOptions options})`；`YlPlayerController.prepareMediaDelivery` 转发同一接口。

- [x] 先写 prepare/cancel/failure/dispose 的回归和通道测试。
- [x] 复用现有 HLS remux/HTTP server，以独立租约持有，无需隐藏 AVPlayer。
- [x] 每个播放器至多一个待准备和一个已交付资源；取消等待/销毁释放生产器，状态不泄露源凭据。
- [x] 保持原 AirPlay 行为，执行交付资源和原 AirPlay/RTMP 相关原生回归。

## 任务 4：平台发现支持、示例与集成

文件：新包 Android 轻量 plugin（组播锁）、Dart 平台调用、示例与中文 README；文档平台矩阵和验证记录。

- [x] Android 在扫描和持有会话时按引用计数持有组播锁，停止/销毁释放；不新增播放器依赖循环。
- [x] 示例覆盖搜索设备、源输入、DLNA 控制、AirPlay 系统按钮、取消和返回本地。
- [x] 文档说明 iOS multicast entitlement、局域网权限、macOS 网络 entitlement、脚本源接入和直播格式限制。
- [x] 运行受影响 Dart 测试、静态/公共 API 检查、Apple 与 Android 构建；明确记录实际可完成的设备验收。
- [x] 独立代码复审并修复实质问题，完成最终验证记录。

## 执行记录

- 设计已获用户确认；Google Cast 已排除。现有检查点为当前 HEAD，设计文档尚未提交。
- 实施方法：主任务负责公共控制层和整合，独立模块按共享契约并行；本次不自动提交。

- 实现与软件验证完成，详见 [验证记录](../reports/2026-10-20-optional-casting.md)。独立复审问题已修复；真实接收端验收、iOS multicast 授权与通用双架构模拟器工具链问题按记录保留边界。

## 后续复审优化（用户已要求全部实施）

- [x] 返回本地在远端停止完成后复核取消代次、销毁、AirPlay 和本地身份，并清理取消后的迟到恢复。
- [x] Apple 直播增加共享原生准入，拒绝的新请求保留已有准备和租约；限制准入队列。
- [x] SSDP 同 UUID 的 LOCATION 变化刷新描述，隔离旧响应并保留请求与缓存上限。
- [x] 统一发现状态和异步错误，公开有效会话能力；示例显示状态并按能力禁用按钮。
- [x] SOAP 显式发送 UTF-8 Content-Length，增加非 ASCII 元数据验证。
- [x] 完成针对性测试、独立复审及优化验证记录。
