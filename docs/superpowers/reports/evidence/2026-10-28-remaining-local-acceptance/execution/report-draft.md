# 当前条件下剩余项集中验收（2026-10-28）

本轮从 `63f5a6188b604eaf28d00238593f8582fc3de2b4` 的TV优化分支建立独立工作树 `codex/remaining-local-acceptance`。没有修改播放器生产行为、协议、依赖或阈值。另一聊天负责的iOS恢复不在本轮范围；仅只读复用其已提交 `83deb9ed` 的120秒诊断生成器、汇总器与公开入口测试，不重复开发或占用其设备。

## 完成的修复

1. CI与快速门禁现在将根 `pubspec.lock` 变化纳入Android/Apple原生检查，消费者检查同时覆盖根 `pubspec.yaml` 与lock。回归实际执行workflow选择shell与临时Git提交；将该门禁回归纳入foundation。
2. 新检出缺少被忽略的Gradle启动器时，两个Android门禁入口先运行固定Flutter3.44的 `build apk --debug --config-only --no-pub`，再执行JVM测试。本机工具运行确认生成启动器且Gradle版本文件哈希未变；配置失败即停止，不吞错。
3. Android集成测试回调探针补齐 `onNetworkBytesReceived(loadId, bytes?)` 与延迟ACK。原测试缺失处理器会导致原生传输失败并提前释放，进而出现15秒超时。新增真实binary-messenger分发回归覆盖双参数、nullable bytes及ACK等待。
4. 控制器测试成功工厂由过时schema7改为当前 `AndroidCodec.schemaMajor`（8）；不改变生产握手或错误协议测试。原8项protocol.mismatch失败保留。
5. 多播放器回滚用例将404响应的预期错误从泛化network.failed同步到现有Android契约network.http_status.404。核对YlFailureMapper及既有JVM映射测试；未放宽原播放器继续播放、第二播放器无会话及单次请求断言。
6. 脚本测试明确清除自身控制的调用者API/skip环境，避免分阶段验收标志污染用例。

## Android弱网诊断

Android TV API36、arm64模拟器 `emulator-5580`；不是物理TV、API24或32位资格。每次构建均记录APK SHA256与进程/服务退出码，因此属于源码绑定的debug诊断，不冒充冻结产物性能基线。40秒基线与120秒扩展素材分别保留。

| 模式 | 次数 | 实际观察 |
| --- | --- | --- |
| auto，40秒 | 2 | 640×360→320×180；未恢复升档；恢复阶段开始后最后视频请求仅剩约0.50/0.42秒 |
| auto，120秒 | 2 | 640×360→320×180→640×360；高档请求在恢复后2.035/3.019秒出现 |
| caps，40秒 | 2 | 全程320×180，遵守上限 |
| fixed，40秒 | 2 | 全程640×360，遵守固定选择 |

两次120秒输出尺寸恢复的采样区间分别为网络恢复后17.006–17.068秒、17.889–17.946秒。输出采样不能冒充物理画面/音频时钟。全部8次播放到素材末尾，进程、汇总、服务退出0，各网络阶段都有媒体字节写入，violations为空。caps一次有3次重缓冲，fixed两次分别有1次；完整计数及nullable统计保留在原始summary，不声明零卡顿。

短素材的请求尾部限制与长素材两次恢复，支持“40秒未升档不能据此断言恢复策略失效”的诊断。未修改Media3选择策略；完整CAP-ABR仍未验收，所有capture的capabilityAccepted、physicalOutputVerified、baselineComparable保持false。

## 集中验证

| 检查 | 实际结果 |
| --- | --- |
| foundation前半段 | 652项Python用例：650通过、2条件跳过；平台接口Flutter137项通过 |
| foundation失败点修正后续跑 | 根播放器1706、example110、Android适配100、Android示例1、Apple适配157、media_delivery11、cast48、cast adapter19项通过；独立cast消费者48项通过 |
| 静态/接口/生成与产物 | flutter analyze退出0；公开面、Pigeon与消费者源码一致性通过；FFmpeg契约3切片/5架构/57符号与9个预期失败检查通过；452个Dart文件格式无变动 |
| Android JVM | 613项通过、0失败、0跳过；含真实MediaMTX1.21.1对端，进程组、代理及监听器清理收据complete=true |
| Android公开集成 | progressive 2、HLS 3、session-replacement 3、multi-player rollback 1项通过；CADENCE_PENDING |
| 额外本机检查 | source_resolver 65项、启用真实解码探针3项通过；独立Android消费者assembleDebug通过；九包dry-run退出0且0 warnings；compositor探针仅编译通过，未录屏/请求授权 |

foundation采用分段证据：`foundation-final.log`在旧schema失败前的阶段与修正后的`foundation-resume.log`共同覆盖脚本；没有把失败的完整命令改写为退出0。两项Python跳过分别因未配置固定CGL研究构建、缺本机历史R19运行产物；两者均不算通过。保留既有Swift/Gradle弃用警告，未据此修改Apple生产代码。

验收过程并非一次全绿：首轮运行器错误继承skip标志；首次JVM启动器缺失；真实session-replacement因漏接回调失败；foundation中的8个旧schema测试失败；回滚测试旧HTTP错误码断言失败；补跑运行器还曾使用错误相对路径导致3项exit127（测试未启动）。cadence首轮期间专用模拟器不再响应adb shell（有界健康检查超时），关闭本轮模拟器后该测试退出79；中断没有判作通过。仅重启本轮只读实例后定向补测。重启后的Flutter设备发现还被另一模拟器5554的getprop阻塞；仅终止本轮Flutter自身的该只读查询后继续，另一模拟器与全局adb未被操作。上述原始失败全部归档，修复后仅补跑受影响和此前未运行部分，没有重复8次弱网或已通过JVM/消费者矩阵。

## 保留的未完成项

- P02/P03：物理可听多音轨、音视频/字幕同步、保护/HDR/外接输出；最低系统、Intel、低内存32位及热稳态/软件解码矩阵。原iOS33项解码/输出失败与R19条件跳过不由本轮消除；另一聊天最终结果待其独立记录。
- P04/P05：物理设备重复资格、同构建基线与业务原始直播源及长时实测。本轮Android长诊断有恢复证据，iOS恢复仍由另一聊天处理。
- P06：DRM证书、许可证、授权素材、HDCP/安全解码器物理路径。
- P07：独立参考目标及容差、实际use_previous、完整DM/trim/CM/NLQ和原生Dolby Vision路径。
- P08仍有工程未闭环项：历史119.084ms READY内部因果链、系统内部资源A5上界缺少证明；它们不能全部归类为缺设备。保持候选默认关闭、50ms/3帧、100ms时钟新鲜度、0系统丢帧、3秒释放条件，不凭模拟器或编译结果放宽。
- 远程CI及完整发布资格未完成；无推送、合并、上传包或发布。

Apple原生、media_core、media_delivery、platform_interface及根依赖相对 `c07fba9f` 没有生产范围变化（空Git diff核对）；复用历史原生执行证据，并明确保留失败。共享Flutter视图已有TV分支变化，本轮基础Flutter测试覆盖当前源码；并未将历史Apple原生结果冒充当前新执行。

## 台账与证据

源快照更新为 `b4651f1fd23bf40cbc2384b2a0f39c0f0f90b0f736ca918b71aa25a895972eb5`，相对旧快照36个文件差异来自已在基线中的TV变更；本轮修复仅位于CI/工具/测试，不改变该生产范围哈希。冻结baselineCommit仍保留 `a31b624a`。102行状态不提升：67 implemented、34 partial、1 unreviewed；30 external_missing、3 failed、69 not_run、0 passed，acceptance仍为空。Android ABR nextAction改为长诊断已恢复后所需的物理资格，不再把短素材未升档直接列作已证策略故障。

GATES_PENDING

REVIEW_PENDING

完整日志、失败尝试、命令、复用工具哈希、APK哈希、JVM XML、消费者与dry-run记录、执行账本在 [证据目录](evidence/2026-10-28-remaining-local-acceptance/)。大型文本用gzip无损归档；`SHA256SUMS`绑定归档文件，原始失败未覆盖。证据不包含下载二进制、虚拟环境或重复媒体。
