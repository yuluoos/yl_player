# 授权 DRM 验收入口

P06 Task4 的准备工具。预检离线运行，不访问媒体、不发送许可证 POST。配置完整只表示 `not_run`，不证明授权有效、媒体哈希匹配、真实设备或 DRM 播放通过。

## 私有资源表

将 `inventory.example.json` 复制到仓库根目录已忽略的 `.drm-acceptance-private/inventory.json`，目录权限设为 700、文件 600。模板无真实端点或凭据。三行分别为 Android DASH/Widevine CENC、iOS HLS/FairPlay、macOS HLS/FairPlay。可以只提供当前可测平台的行，但不能据此宣称三端完成。

每行填写：

- `mediaUrl`、`licenseUrl`：HTTPS，禁止 URL 用户名/密码和 fragment；签名 URL 只存私有配置。
- `licenseHeaders`：非敏感请求头；认证/令牌放 `licenseCredentials`。不允许覆盖 Content-Type、Host 等传输头。当前生产传输使用原始二进制请求/响应：Apple SPC→CKC；服务如要求 JSON/XML/base64 封装，需要先实现受控适配，不能在此假设兼容。
- Apple `certificateBase64`、`contentIdBase64`：应用证书和供应方定义的内容标识，标准 canonical base64；Android 两项为空字符串。
- `mediaSha256`：供应方可核验样本的 SHA-256（小写64位）；预检只报告声明值，不下载媒体或验证哈希。
- `authorizationScope`：固定 `drm-playback-testing`；`authorizationExpiresAt`：UTC 秒精度，例如 `2026-10-01T00:00:00Z`。执行前重验有效期。此声明不能替代授权证明，证明保存在私有资源台账中。
- `deviceId`、`deviceModel`、`osVersion`、`physicalDevice: true`：目标物理设备声明，测试仅自动检查 OS 平台；操作者另行核对实际设备、构建和输出条件。
- `outputPath: internal`：初始入口只覆盖内屏；`seekPositionMs`：1–600秒内、且距媒体结尾至少2秒的可 seek 位置。选择足够长的点播样本。

```sh
dart tool/drm_acceptance/prepare.dart .drm-acceptance-private/inventory.json
```

退出码：0=所选配置完整（仍未验收），2=缺项或非法配置。报告仅包含固定用例标识、缺项名和声明哈希。缺项为 `external_missing`；非法结构只输出 `drm.acceptance_config_invalid`，不回显输入/异常原文。

## 物理设备基础生命周期

为每次运行选一个新的输出文件名。工具只允许直接写入私有目录的新文件，以 600 权限创建；已有文件、符号链接、目录外输出均拒绝。以下从仓库根目录运行，替换设备 ID，并按平台选择固定用例 ID：

```sh
dart tool/drm_acceptance/prepare.dart .drm-acceptance-private/inventory.json \
  android-widevine .drm-acceptance-private/android-run-001.json && \
(cd packages/yl_player/example && flutter test integration_test/drm_lifecycle_test.dart \
  -d YOUR_PHYSICAL_DEVICE_ID \
  --dart-define-from-file=../../../.drm-acceptance-private/android-run-001.json)
```

Apple 使用 `ios-fairplay` / `macos-fairplay`。无配置、过期、平台不匹配会失败，不 skip。只有前置命令退出0才运行 Flutter；不能忽略退出码复用旧文件。

Dart define 会进入构建产物，因此这些验收包、临时构建和完整设备日志同属私有资料，不发布、不提交，不开启 verbose 后公开日志。工具及集成摘要脱敏不保证外部 SDK/OS/Flutter 工具原始日志脱敏；只把审核后的 `YL_DRM_ACCEPTANCE=` 摘要并入报告。

入口通过公共生产控制器观察 ready、播放、受保护 view 描述符/首帧信号、进度、暂停、seek、继续、替换和停止后的旧会话拒绝，并在清理后输出摘要。`automatedLifecycle: passed` 仅指这些自动观察通过，`physicalAcceptance` 保持 `not_run`。不截图、不读取受保护像素；首帧信号不能代替实际画面/声音观察。

## 受控许可证负向入口

`drm_fault_test.dart` 补充拒绝、超时、在途 stop/cancel 三个独立用例。每个用例先使用私有配置完成真实授权播放和受保护首帧/进度观察，再创建同一媒体的候选加载，将**整个许可证端点配置**替换为设备进程内随机端口的数字回环服务。真实许可证凭据不复制到该端点；服务不转发、不保存 challenge、不返回可用许可证。

- `denied`：本地 POST 返回403，必须收到 `drm.license_denied`，原会话/保护视图保留且继续推进。
- `timeout`：本地 POST 不返回响应头，2秒许可证期限必须收到 `drm.license_timeout`，原会话/保护视图保留且继续推进。
- `cancel`：确认收到非空 challenge 后才调用公共 `stop()`，必须收到 `load.cancelled`，旧会话失效且保护视图撤销；随后重新加载真实授权源并观察新会话进度。取消用例的许可证期限为30秒，以免把自然超时当作取消。

准备一个新私有运行文件后，选择一项执行（后续两项分别使用 `timeout`、`cancel`）：

```sh
dart tool/drm_acceptance/prepare.dart .drm-acceptance-private/inventory.json \
  android-widevine .drm-acceptance-private/android-denied-001.json && \
(cd packages/yl_player/example && flutter test integration_test/drm_fault_test.dart \
  -d YOUR_PHYSICAL_DEVICE_ID \
  --dart-define-from-file=../../../.drm-acceptance-private/android-denied-001.json \
  --dart-define=YL_DRM_FAULT=denied)
```

Apple 仍需使用对应平台的资源行。要求可反复取得许可证、能创建独立候选会话、足够长的授权点播样本。若系统缓存导致没有新的许可证 challenge，测试失败，不把缓存命中当作负向通过。缺配置、未知用例、无正向基线、未收到 challenge、错误码不匹配、当前会话被替换或清理失败均不能通过。

`automatedFault: passed` 只表示受控故障的公共状态观察；`providerNegativeAcceptance` 和 `physicalAcceptance` 固定为 `not_run`。本地403不证明真实提供方拒绝/到期策略；取消后的新会话进度不证明真实迟到有效密钥注入已测试。密钥轮换、实际过期、系统后台和物理输出仍需独立证据。本轮仅在宿主机测试故障服务、公共传输和桥接，并编译入口，未执行上述设备命令。

## 仍需独立完成的 Task4 证据

该入口不是完整 DRM 验收矩阵。另行提供并运行可控制的拒绝、超时、明确过期、密钥更新/rotation、断网恢复、后台恢复、跨 Period、切轨、在途许可证取消用例；记录授权证明/资源来源、实际媒体哈希、实际设备和构建身份、真实显示与声音观察。与 P02 核查字幕/几何，与 P07 核查外接保护/HDCP。禁止将生命周期信号或预检当作上述证据。

当前没有授权资源，`resource-status.json` 是空私有表的真实离线预检结果（退出2，网络请求0）。三平台仍为 `external_missing`。资源与物理验收齐全前不勾选 CAP-DRM。

## 工具回归

```sh
python3 -B -m unittest discover -s tool/drm_acceptance -p 'test_*.py'
flutter test --no-pub packages/yl_player/example/test/drm_acceptance_case_test.dart \
  packages/yl_player/example/test/drm_acceptance_runtime_test.dart \
  packages/yl_player/example/test/drm_fault_server_test.dart \
  packages/yl_player/example/test/drm_acceptance_owner_test.dart
```

Python 测试要求 `dart` 在 PATH，使用临时独立仓库布局和虚构凭据，不触碰用户私有资源。两类测试已进入 `tool/check_foundation.sh` 的测试发现路径。
