# 当前设备剩余功能与集中验收（2026-11-05）

本轮完成已定位、可在当前环境修复的工程问题，并完成集中验证及定向补验。**不是整组或发布验收完成声明**：iPhone 同构建格式矩阵为 **39/40**，Android 为 **36/40**；两端各保留完整 44 格分母（40 必测、2 MPEG-2 诊断、2 损坏输入）。未授权的 DRM/Dolby 资源、最低系统/其他硬件、P08 证据缺口和远端 CI 条件继续保留。

基线 `13f45f7e`，工作分支 `codex/remaining-device-acceptance`。代码提交：`df5ddc03`、`55d91b02`、`edfdb164`、`4084e2e7`。本轮没有推送、合并或发布。

## 完成的工程修复

1. CI 显式为 `setup-android@v3` 选择 `platform-tools`，避免默认请求已移除的 `tools` 包。原始失败来自远端 [run 42055064300](https://github.com/yuluoos/yl_player/actions/runs/42055064300)。配置依据为 [action v3 输入声明](https://github.com/android-actions/setup-android/blob/v3/action.yml)。
2. Apple VP9 补充解码器注册增加编译条件，保留原有 iOS 26.2 运行时门槛；本轮实际 Xcode 27.2（27B52）构建通过。旧 Xcode 16.4 的原始消费者编译错误已保留，修复后尚未在该 SDK 重编译，不宣称远端已通过。[Xcode 配套编译器版本](https://developer.apple.com/support/xcode/)是该条件的适用边界。
3. 修复三处验收契约漂移：历史 skip 文件在 `8670cd9d` 增加 PCM 附件后的哈希对账；已存在 SwiftPM `.dynamic` 声明的测试断言；独立 host 模板的 analyzer 范围及两个花括号 lint。没有扩大硬件跳过条件。
4. SwiftPM 消费者检查真实动态 framework 中的插件符号，并要求宿主实际链接它。iOS 与 macOS `Versions/A` 安装路径分别检查；既有架构、最低 OS、Flutter/FFmpeg 链接检查全部保留。实际 Mach-O 负向对照保留嵌入 framework、移除宿主链接，仍被拒绝。
5. Android 初始截图与公开首帧通知并行等待，二者都必须成功；Apple 采集顺序不变。另修复大段原始证据的 ADB 传输：旧 `exec-out` 曾在退出 0 时仅交付 75,264/627,138 字节，改用无 PTY 的 `shell -T`，记录传输命令并保留退出码及完整 JSON 校验。缺文件负向对照返回非零状态。并行截图不是该截断问题的因果解释，也不构成性能优化证明。
6. AC-3 5.1 验收同步已有生产契约 `d99481b3`：遵循源 Lo/Ro 系数。独立安装的 FFmpeg 8.0.1 读取冻结素材全部 125 帧，中置系数为 `0.5946035385131836`，环绕为 `0.5`。参考值绑定素材 SHA，保留原 `0.08` 误差、声道隔离及 LFE 排除，新增旧系数拒绝和错误素材拒绝对照。没有根据播放器输出拟合系数，也没有改生产下混代码。[提取程序、命令和元数据](evidence/2026-11-05-remaining-device-acceptance/ac3-downmix-metadata/manifest.json)

## 集中验证结果

| 范围 | 结果及边界 |
| --- | --- |
| foundation | 按失败点接续完成；两个过时契约修复后只补跑受影响用例。Dolby 工具套件的 28 个条件跳过保留，不算设备能力通过。 |
| 受影响音画门禁 | 85 项通过；新增下混用例先出现 2 项预期失败，再转为通过。原始两路 PCM 离线重放也通过。 |
| Android 原生 AC-3 5.1 | API 36 模拟器上的原生 instrumentation 测试 1 项通过、0 失败/跳过，包含双向 seek 与 PCM 系数验证。[JUnit 回执](evidence/2026-11-05-remaining-device-acceptance/android-native/ac3-downmix.xml) |
| 源码解析器 | 正确的包内入口 65 项通过；首次从 workspace 根入口运行缺 native-assets 的失败日志保留，未因此修改实现。 |
| 静态/结构 | analyzer 零问题；Pigeon 一致性、公开接口、历史迁移/来源检查、8 项兼容工具测试通过；compositor probe 仅编译通过，未声称实际物理取证。 |
| 独立消费者 | Android、iOS CocoaPods、macOS CocoaPods、iOS SwiftPM、macOS SwiftPM 五种构建/链接通过。macOS 明确启用既有 `--lipo-compat`；不是默认工具链无适配通过，也不是最低 OS 运行时验收。 |
| 发布打包 | 9 个包 dry-run 零警告。先复用已通过的 4 包，再补跑剩余 5 包；最后的 Android 测试源修改后仅补验该包。没有实际发布。 |
| Apple FFmpeg 严格产物门禁 | 在下载锁定的源归档时 TLS 失败；直接下载和使用现有系统代理的下载均限时失败。完整门禁未通过，未绕过签名/哈希检查。 |
| 性能与发布准备 | P08 正式基线 0/4；台账保持 `releaseReady=false`。结构有效与部分通过不等于发布准入。 |
| 独立复审 | 一次集中代码复审，后续真实失败触发的局部修复仅作定向复审；未发现阻断问题。复审者复用执行证据，没有重跑套件。 |

检查日志、失败、定向修复及复审记录见 [检查归档](evidence/2026-11-05-remaining-device-acceptance/checks.tar.xz)；消费者完整构建/链接日志见 [消费者归档](evidence/2026-11-05-remaining-device-acceptance/consumers.tar.xz)。

## 同构建矩阵及失败保留

**iPhone 16 / iOS 27.2**：冻结应用清单 SHA `8aad8109fcc9f15928245e68c0c2592501a5ea7a06f390631f5f38c31b02fbce`。首次完整矩阵 37/40。AV1 文件的 LLDB 启动超时随后补验通过；HEVC HTTP 原先缺少配对样本，首次补验发生设备连接中断，再次明确补采成功。同一冻结应用、同一 matrix ID 下最终选定 39/40，原始和中间失败全部保留。唯一剩余必测格为本地 MP4：公开生命周期、渲染取样通过，但 `played_sample_clock_unverified`，不能把 AVPlayer source-pull 当作实际已播放样本时钟。

[最终逐格结果](evidence/2026-11-05-remaining-device-acceptance/ios/matrix-result.json) · [选定原始记录](evidence/2026-11-05-remaining-device-acceptance/ios/records.json.xz) · [全部采集尝试](evidence/2026-11-05-remaining-device-acceptance/ios/raw-attempts.tar.xz)

**Android API 36 / arm64 模拟器**：最终 APK SHA `294a97a155a3d5195257af38c9bbdf149a7a2abb474f75eda2587a53ce4526cf`。专用配置为 720×1280、2 核、2 GiB RAM、12 GiB 数据分区、宿主 GPU。首次完整最终构建矩阵 30/40；三个 ADB 传输中断、一个 AVI HTTP 配对缺样、两个过时下混断言分别完成六项定向补验，均通过，最终 36/40。剩余 AV1 和 HEVC Main10 的文件/HTTP 四格实际返回 `decoder.unavailable`，仍计入 40 项必测分母，未启用未经准入的软件解码。

早期旧 APK 的完整失败矩阵、旧模拟器存储不足、宿主 GPU 预检超时、新模拟器上的中断采集及截断原始字节全部保留，不与最终 APK 混算。首轮功能采集曾与其他本轮任务并发；定向补验在其他采集/构建结束后串行执行。环境调整不是单因素实验，不据此作性能因果或热稳态结论。

[最终逐格结果](evidence/2026-11-05-remaining-device-acceptance/android/matrix-result.json) · [选定原始记录](evidence/2026-11-05-remaining-device-acceptance/android/records.json.xz) · [六项选择记录](evidence/2026-11-05-remaining-device-acceptance/android/attempt-selection.json) · [全部采集尝试](evidence/2026-11-05-remaining-device-acceptance/android/raw-attempts.tar.xz)

汇总仍由现有 `bound_matrix.summarize` 重放原始数据决定；只替换本次明确补验的失败格子，成功格子未重跑。每次补验都有新的 run ID、真实 collector 退出码及同一冻结制品身份。每次原始结果保持原样，记录重压缩为 XZ 时保留解压内容 SHA；不重复归档可由各子记录重建的多份聚合副本。

## 保留的具体缺口

| 项目 | 缺口 / 下一步条件 |
| --- | --- |
| Android 格式 | 当前模拟器无可用 AV1、HEVC Main10 解码器；需相应真实硬件，或另行完成受预算约束的软件解码准入。不能用模拟器结果代表物理屏幕/扬声器。 |
| iOS 本地 MP4 | 还需实际播放时钟或受控物理音画测量链；这是证据能力限制，不能仅用 source-pull、更多日志或本轮 39 格通过替代。 |
| P06 DRM | 授权素材、许可证端点/凭证、Apple 证书等输入仍缺，当前预检保持 external_missing。 |
| P07 Dolby/输出 | 授权参考素材、完整显示/音频输出及 HDMI/直通链等条件不足。既有工具测试、软件解码不能冒充物理链验收。 |
| P08 历史 READY | 119.084 ms 历史事件仍缺可判定原因的证据；当前没有新的可检验因果假设，不重复无变化长播。新增 firstFrameUs 是等待结束时刻，不能证明该历史事件。 |
| P08 A5 | 不透明系统内部资源上界仍未证明，候选保持不准入；账本归零和更多循环不能替代系统上界证明。该项不是简单缺设备。 |
| 正式性能基线 | 仍缺最低系统/Android 低内存 32 位/Intel 等设备及冻结的产品阈值、校准与输出条件；M1 专项资格不等于全平台基线。 |
| 发布/CI | 最新已查远端运行属于旧修订且失败。本地候选未推送，旧 SDK 重编译与新远端 CI 尚未执行。FFmpeg 精确复现另需锁定的 Xcode/SDK/meson/ninja 全套环境，不能将缺 meson 当作唯一障碍或改锁规避。 |

历史 [iPhone 33 项回归](2026-10-29-ios-format-physical-followup.md)、[M1 40/40 矩阵](2026-11-03-macos-qualified-format-matrix.md)、两轮约 1204 秒 AV1 资格及已完成 DASH 证据按原范围保留，未无变化重跑，也未把绑定原签名制品的资格迁移到新编译制品。

本轮仅关闭自己创建的 Android 模拟器，iPhone 最后成功采集取得停止回执；未操作另一任务的 iPhone Duo 模拟器。共享 Flutter SDK 未替换，USB 使用的 arm64 iproxy 仅放在本轮私有 SDK 克隆中。清理仅涉及本轮可再生中间文件，最终制品和原始证据保留。

发布台账仅追加本轮证据、刷新源码指纹和后续动作；CAP-FORMAT 两平台仍为 failed，未把局部结果升级为整组通过。[发布准备回执](evidence/2026-11-05-remaining-device-acceptance/release-readiness.json) · [正式基线回执](evidence/2026-11-05-remaining-device-acceptance/performance-readiness.json)
