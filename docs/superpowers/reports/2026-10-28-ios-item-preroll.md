# iOS 候选预滚、准备撤销与预算验证

基线 `0464c7bb`，分支 `codex/abr-recovery`。本轮仅修改诊断夹具、镜像及采集工具，生产自动恢复仍未接入。承接[路由暂停报告](2026-10-28-ios-route-pause.md)，完整原始失败、源码快照、命令、采样和 xcresult 见[证据目录](evidence/2026-10-28-ios-item-preroll/)。不发布。

## 已确认结论与实现

真实本地媒体测试证实，预滚 item 即使先从候选 AVPlayer detach，再交给第二个 AVPlayer，仍会抛 `NSInvalidArgumentException: An AVPlayerItem cannot be associated with more than one instance of AVPlayer`。该方案撤销；保留 `preroll-green` 完整崩溃及当时代码。没有用延时规避，也没有把后续不同方案的通过覆盖这次失败。

替代的显式诊断模式为 `asset-preroll`：静音、禁止外接的候选 player 等待 ready，精确 seek，再 preroll；成功后 detach 并丢弃候选 item，以同一 asset 创建全新 item，经既有工厂一次性安装。主播放器仍执行原精确 seek。共享 asset 只可能预热资源，不代表转移解码状态。

准备期限为最多2秒且不超过原票据到期。每个等待阶段检查任务取消、播放意图和期限，失败取消 preroll/seek/asset、释放候选、撤销其 loader 请求。复审补上 ready 回调前的有效性复核，同时保留回调后的检查，避免最后一次等待期间过期或失效的票据仍触发暂停注入。仅成功准备、原票据授权和旧 item 身份都成立才安装。

`pause-during-preparation` 在首张票据的候选真正 ready 后、seek 前暂停旧 backend 并作废票据，2秒后显式恢复原播放。该场景仅覆盖这一明确阶段，不能代表所有 seek/凭据/约束竞态。预算回归确认两次失败/撤销仍消耗两个源级预算，退避保持500/1000ms，没有第三张票据。

采集器要求模式逐行回显，并拒绝缺少 ready、已detach、未复用预滚item、全新item已安装、旧item在准备期保留等证明的成功安装事件。未触发不会被当作自动恢复或撤销通过。

## 真机对照

设备 iPhone17,3 / iOS27.2，沿用已授权本地开发签名。素材120秒、原生140秒、采集240秒。先注册六轮顺序，前五轮用独立零延迟诊断配置；第六轮用原冻结配置。最终 ready 前复核修复后另跑一轮暂停撤销，单独记录源码/制品身份，不能冒充七轮同一制品。

| 运行 | 采集 passed | 片尾位置（秒） | 票据/准备结果 | 替换新帧间隔 |
| --- | --- | --- | --- | --- |
| normal-1 | True | 120.027618 | 1:installed / warm=无 | 138.582 ms，清空0 |
| warm-1 | True | 120.011863 | 1:installed / warm=ready | 207.507 ms，清空0 |
| normal-2 | True | 120.049580 | 1:installed / warm=无 | 85.567 ms，清空0 |
| warm-2 | True | 120.024079 | 1:installed / warm=ready | 206.774 ms，清空0 |
| warm-pause | True | 120.024925 | 1:preparationFailed / warm=cancelled；2:installed / warm=ready | 119.509 ms，清空0 |
| original-control | True | 120.023523 | 零票据 | 无替换 |
| final-warm-pause | True | 120.030549 | 1:preparationFailed / warm=cancelled；2:installed / warm=ready | 207.637 ms，清空0 |

普通替换两轮为138.582/85.567ms，asset预滚两轮为207.507/206.774ms；本组没有缩短空档的证据。候选预滚期间旧播放器继续出帧，但额外准备成本及最终重新 seek 没有带来所需收益，暂不接入生产。样本只支持本组观察，不能推出所有网络下必然变慢。采样 `continuityAccepted`、物理输出与音画同步标志仍为 false；零纹理清空不是屏幕无黑帧或音画/字幕连续性验收。

原配置对照到片尾120.023523秒：首窗1151979bit/s合格，第二窗完成前自然升高档，零票据；没有满足双窗后漏触发的证据，也未复现旧63.900秒停顿。片尾代理340次入队/340次上游完成（含4次取消完成），活动任务和待发送均0、其他完成错误0。

预滚两轮分别用时1.261/1.056秒，准备期间旧输出新增30/25帧，候选代理接收654629/601465字节。这是额外预热开销，尚无新帧空档收益。warm-pause首次主动暂停造成全程最大出帧间隔2123.649ms；表中119.509ms仅指第二票替换边界，不能掩盖主动暂停。

最终修复后补跑同样实际撤销首票，warmupOutcome=cancelled、outer outcome=preparationFailed，候选活动任务和待发送归零；第二票使用原1000ms退避并成功安装，到片尾120.030549秒。该轮主动暂停的全程最大出帧间隔为2130.155ms，第二票替换边界207.637ms。它验证撤销与预算路径，不证明空档改善。

原配置哈希 `4e4f256c59465f4a573d6ab1c48f7a7571294638025088d0cddba9325f5032ea`；独立诊断配置哈希 `9f63acdf1ab0ce92c5565bc3a750478f0c6c5ba76cef88c7e1092cfcd89b01f1`。原策略先高后低、有逾期、连续缓冲至少5秒、剩余至少20秒、两个连续8秒窗且每窗至少3请求/955000bit/s，源级最多两次500/1000ms退避，均未改。诊断配置不替代原配置验收。

## 开发失败与集中验收

保留选项/场景/回执红灯。原生 `preroll-red` 为行为红灯，`preroll-green` 为2通过1崩溃，`preroll-fresh` 为缺少 await 的编译失败（0执行），`preroll-safe` 为3通过/0失败/0跳过。三项新增用例覆盖挂起真实请求的撤销/任务取消/超时、真实本地媒体预滚与全新item重新seek播放、失败及撤销不退还预算。它们不是完整ABR能力验收。

最终 iPhone 七类167项、macOS六类142项通过，均0失败/0跳过；完整测试树保存。包含DASH loader、Apple session/publication、network byte source、platform services、nonblocking metadata，以及仅iOS现有live reconnect类。网络工具114项、完整benchmark发现入口294项（含15项台账测试）通过；镜像声明iOS832/macOS876及固定历史来源检查通过。声明数不等于执行数，无媒体环境的探针不代表媒体验收。结构检查通过，两个require-ready仍按未就绪退出1。未将这些受影响范围回归当作完整Dart/Android/全部Apple/独立消费者验收。

保留原生主线程/QoS运行警告，以及iPhone devicectl诊断采集不完整的日志；这些不是测试失败，不能宣称警告已修复。完整xcresult按实际生成内容保存。

11组历史证据2701个清单文件逐一验证哈希不变。生产源码身份仍为 `9fd66d341470a59bbc1eca827c85f52e63b81766ce7a0f361477e1abe7db8064`；本轮诊断源码另有采集/最终身份记录。所有原始失败保留。

独立综合复审已完成：ready前复核问题已修正，无剩余阻断。复审逐一验证295项归档清单、278项原始映射，并将13个xcresult内每个文件与原始bundle比较，内容一致。macOS完整包73345444字节分5块保存，未删附件。归档脚本首次括号语法错误及修正记录也保留；未影响测试结果。后续台账复核与本段复审记录另追加到证据清单。

## 保留未完成项

历史63.900秒缓冲耗尽停顿仍未复现定位；原配置稳定安全自动恢复、缩短替换新帧间隔、修复后真实物理耳机断开、所有准备阶段的seek/凭据/约束竞争、物理音画/字幕连续性仍未完成。完整auto/caps/fixed、多设备/最低系统、DRM/Dolby授权和外接输出矩阵、历史iOS33失败/1skip均保留。上一轮路由暂停修复不证明旧缓冲耗尽失败已解决。

台账只补报告和后续行动，不提高任何完整能力状态或acceptance。保留102行：67 implemented / 34 partial / 1 unreviewed，69 not_run / 30 external_missing / 3 failed / 0 passed。releaseReady=false。仅本地分支提交，不合并主分支、不推送、不打标签、不发布。
