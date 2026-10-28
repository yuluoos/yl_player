# iOS 路由断开暂停误报修复与原配置续查

基线 `160eb42f`，分支 `codex/abr-recovery`；沿用系统排障、测试驱动与集中验收，不发布。前轮见[候选元数据报告](2026-10-28-ios-candidate-preparation.md)，本轮完整失败、采样、命令和 xcresult 见[证据目录](evidence/2026-10-28-ios-route-pause/)。

## 本轮确认的问题

原配置首轮出现终末暂停：位置停在 55.174524468 秒，最后新帧采样 59.628560 秒，观察结束 140.181208 秒，末尾无新帧区间 80552.648 ms。原始采集为失败，没有删除、缩短超时或改成通过。

原生 action 日志显示：53.917922 秒 `audioRoute reason=1`，59.327273 秒 `audioRoute reason=2`；59.879 秒采样已为 rate=0/timeControl=paused，后端却报告 buffering。15 秒后出现 `avplayer.stall_timeout`。此时 item ready、likelyToKeepUp=true，缓冲范围终点 65.984 秒，比当前位置多 10.809 秒。代理已入队/完成 196/196 次，其中 4 次取消、0 次其他完成错误；活动连接、任务、暂停任务和待发送均为零，后续不再新增请求。

[Apple 路由变更文档](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)说明 oldDeviceUnavailable 会令 AVPlayer 自动暂停，以免拔下耳机后意外外放。代码只根据 `playRequested` 和 timeControl 判定 stall，未同步该系统暂停意图，因而将其误报为网络超时。真实事件与同路径红灯回归共同确认这项缺陷；代理数字只支持本轮观察范围，不能证明所有底层回调已结束。

第二轮旧制品对照 `route-baseline-control-0148` 到片尾 120.048347 秒，只有 81.915344 秒 newDeviceAvailable，没有 oldDeviceUnavailable；8 个窗口 628089–882182 bit/s 均不足 955000，未发恢复票据。第一轮也是零票据，单个完整窗口 858115 bit/s 不足，随后自然高档再发生路由暂停。两轮没有满足原双窗口条件却漏触发的证据。

本次 **55.175 秒路由暂停** 与历史 **63.900 秒缓冲耗尽停顿** 不同：后者曾 waiting/rate=1/likelyToKeepUp=false，没有足够边界证据。这一修复不能作为旧失败根因已查清或已修复的证明。

## 修复范围与回归

YlAvPlayerBackend 仅在 iOS 观察 oldDeviceUnavailable，活动且未终末的会话同步暂停意图、取消进度/停顿计时、发布 paused。不会自动重启播放器，不修改宿主 AVAudioSession 配置，也不将 newDeviceAvailable 或 override 当作断开。用户显式 play 才恢复；音频策略为 appManaged 时同样尊重 AVPlayer 的隐私暂停。回调绑定重置和 dispose 时注销观察者，非活动、停止、销毁及 completed/error 会话不处理。

新增可注入 NotificationCenter 用于隔离测试；产品默认仍为系统中心。测试使用真实 AVPlayer、本地 mp4 和独立通知中心，先调用 player.pause 模拟系统暂停，再发送路由事件，不依赖实际拔插耳机。保持原默认 15 秒 watchdog，等待 16 秒检查没有网络错误，然后显式 play 验证位置继续推进。另检查新路由/override、重连、回调重绑、deactivate 与 dispose。

- `route-red`：原行为 1 用例失败；完整 action 内含意图仍为 true、状态未暂停、15 秒后 stallTimeout 等断言失败，不能只凭摘要第一条错误概括。
- `route-green`：同一真机用例 1 通过、0 失败、0 跳过。
- 镜像声明计数第一次按 macOS 不编译该方法误填 872，工具实际数源文本声明为 873；保留失败并修正为 iOS829/macOS873。这些是声明数量，不代表执行数量；新增方法只在 iOS 编译。

原配置与验收条件不变：120 秒素材、原生140/采集240秒；先高后低、有逾期、连续缓冲至少5秒、剩余至少20秒、连续两个8秒窗，每窗至少3请求、至少955000bit/s，源级最多两次及500/1000ms退避。原配置哈希 `4e4f256c59465f4a573d6ab1c48f7a7571294638025088d0cddba9325f5032ea`；用于执行路径观测的零延迟配置哈希 `9f63acdf1ab0ce92c5565bc3a750478f0c6c5ba76cef88c7e1092cfcd89b01f1`，不能替代原配置验收。

## 新帧空档与范围调整

本轮开始拟研究静音候选 player ready→精确seek→preroll→交接 item，保存了计划草案、未实施 helper 草稿以及 Python 选项红灯（既有采集器拒绝 item-preroll）。首个真实失败出现后，优先修复已确认路由误报；没有把草稿加入产品或采集器，没有进行预滚性能测试。草案目录一次完整23项试跑出现2失败/3错误（含环境权限限制及未支持的新模式）；随后聚焦新增选项一项，确认为 invalid candidate preparation 红灯，日志均保留。这些不是最终仓库测试结果。这是未完成的研究项，不计作修复或安全性通过。

前轮已证明元数据 loaded 不等于解码预热；本轮也不放宽最终精确 seek、不把旧纹理算作新帧、不以路由暂停正确处理冒充自动恢复成功。原生系统通知回归与修复后真实物理断开验证须分别列明。独立综合复审无阻断：新用例执行了重绑后通知、deactivate/dispose；没有专门注入排队旧通知或 stopped/completed/error 场景，这些保护目前是源码审查结论。

## 统一验收与台账

修复后四轮媒体使用同一签名制品，全部到片尾，没有音频路由事件；因此这四轮不构成修复后真实拔插/断开验证。两次旧制品对照也具有相同组内制品身份，但与修复后组不同。六轮采集均验证制品运行期间不变、拥有的进程退出；首轮 passed=false 保持。

| 修复后运行 | 终点（秒） | 策略证据 | 新帧间隔/清空增量 |
| --- | --- | --- | --- |
| fixed-original-1 | 120.029730 | 十个窗口263119–889901 bit/s均不足，低档到片尾，零票据 | 无替换 |
| fixed-original-2 | 120.066229 | 33.732秒首个合格窗1095729 bit/s，第二窗前自然高档，零票据 | 无替换 |
| fixed-auto-1 | 120.015800 | 1847301/1670338 bit/s双窗，一次票据/安装 | 120.611 ms / 0 |
| fixed-auto-2 | 120.015948 | 1950216/1878407 bit/s双窗，一次票据/安装 | 134.614 ms / 0 |

两轮安装首退避523.157/518.197 ms，帧间位置差21.150/13.580 ms。未改变准备、精确seek、纹理保留或生产自动策略；这些独立运行不能证明新帧空档改善，零清空也不是物理屏幕、音画/字幕连续性通过。原配置两轮片尾代理分别338/338（1取消）、344/344（4取消），其他完成错误为零、活动任务和待发送均零；仍不能补造历史停顿缺失的观测。

十组旧证据共2415个清单文件哈希不变。最终 iPhone 七类原生合约/生命周期用例164通过，macOS六类139通过，均0失败/0跳过：DASH loader、Apple session/publication、network byte source、platform services、nonblocking metadata，以及仅iOS现有的live reconnect类24项。新增路由方法在iOS执行，macOS没有编译该方法，亦无live reconnect同名类，不能把命令中的选择器当作已执行。完整测试树一并保存。

网络工具111项、完整benchmark Python发现入口294项通过（包含15项台账测试）；镜像及固定历史来源检查通过。无媒体环境变量的探针方法不会执行实际媒体；六轮媒体另列。保留编译/运行警告，没有把这些受影响范围回归当成完整Dart/Android/全部Apple/独立消费者验收。

当前生产源码身份 `9fd66d341470a59bbc1eca827c85f52e63b81766ce7a0f361477e1abe7db8064`。本轮有生产行为修复，不能沿用前轮源码身份冒充新制品。

仍保留：旧63.900秒停顿、原配置稳定安全自动恢复、新帧空档缩短、加载中意图竞争/预算耗尽、真实物理音画/字幕连续性、完整auto/caps/fixed、多设备/最低系统、DRM/Dolby授权、外接输出及历史iOS33失败/1skip。所有原始失败和资源缺项保留，不提高完整能力验收状态，不发布。

发布台账更新当前源清单、报告引用和待办，保留102行全部状态：67 implemented / 34 partial / 1 unreviewed；69 not_run / 30 external_missing / 3 failed / 0 passed，无新增完整acceptance。台账及性能registry的结构检查与require-ready退出记录见证据readiness/。源码匹配不等于发布就绪，releaseReady=false。仅当前本地分支提交，不合并主分支、不推送、不打标签、不发布。
