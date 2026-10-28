# iOS 恢复资格与清晰度策略竞争验证

基线 `024afebc`，本地分支 `codex/abr-recovery`。沿用系统排障、测试驱动和集中验收。承接[准备意图报告](2026-10-28-ios-preparation-intent.md)，[完整证据](evidence/2026-10-28-ios-policy-intent/)保留原始失败、采样、源码身份和完整xcresult。本轮仅修改诊断夹具、镜像及工具，生产自动恢复未接入；不发布。

## 修复和边界

原探针只用preferredPeakBitRate==0判定清晰度策略是否不受限，遗漏preferredMaximumResolution和固定档位。将原判断提取并接回automaticSample后，真机策略回归在受控合格带宽/缓冲输入下确认：width-only、height-only和fixed三种状态都错误预留了1张票据。`policy-red`为1方法失败、3条独立断言失败；完整action保留，摘要只显示首条width错误。它证明诊断资格逻辑有缺口，不代表生产自动恢复曾实际覆盖用户策略。

最小修复要求peak=0、maximumResolution为zero且fixedTrackId=nil。红灯同方法转为通过，无约束控制仍预留1票，三类限制和码率限制均为0票。带宽、窗口、剩余时间、缓冲、预算与退避数值未改。

新增caps-during-preparation和fixed-during-preparation，均仅允许asset-preroll。原生首票候选真正ready后，作废旧票据，通过现有backend.replaceActiveDash提交另一个由同一manifest快照准备的320宽度上限或固定低档资产。事件记录实际调用成功和item变化；主采样记录尺寸上限、固定ID和资格。新活动loader转移所有权后不会被defer discard取消，旧自动候选则取消preroll/seek/asset并清理自己的loader。

这两轮是backend实际媒体路径的策略注入，不是完整public-host命令端到端矩阵。新generation来自用户策略，不能算作自动恢复成功。原事件分类preparationFailed搭配warmupOutcome=cancelled表示旧候选失效取消，不是播放器故障或用户新策略失败。发生策略切换时按原规则清空纹理，未将该行为包装为连续性优化。

Python不匹配场景红灯1方法4子失败保留，修复后accesslog完整定向27通过。镜像声明iOS836/macOS880，不能冒充实际执行数量。

## 真机观测

设备iPhone16（iPhone17,3）/iOS27.2，沿用已授权开发签名。预登记同一构建四轮顺序：caps、fixed、无约束auto-control、原配置original-control。前三轮用独立零延迟诊断配置，最后一轮用原冻结配置。素材120秒、原生140秒、采集240秒。

| 运行 | 采集passed | 片尾位置（秒） | 自动票据/候选结果 | item变化处新帧间隔 |
| --- | --- | --- | --- | --- |
| caps | True | 120.029655 | 1:preparationFailed / cancelled | 111.995ms，清空1 |
| fixed | True | 120.029935 | 1:preparationFailed / cancelled | 195.526ms，清空1 |
| auto-control | True | 120.020066 | 1:installed / 无 | 154.842ms，清空0 |
| original-control | True | 120.022917 | 零票据 | 无替换 |

caps：实际策略提交及item变化=True，旧候选取消=True；后续337条主采样保持新策略=True，新策略后2082次新帧提交的宽度集合为[320]，均不超过320=True。没有自动恢复安装=True；只消耗首票且未退回=True。全程最大新帧间隔324.561ms。

fixed：实际策略提交及item变化=True，旧候选取消=True；后续336条主采样保持新策略=True，新策略后2081次新帧提交的宽度集合为[320]，均不超过320=True。没有自动恢复安装=True；只消耗首票且未退回=True。全程最大新帧间隔331.314ms。

auto-control窗口bitrate：1220637(firstQualifiedWindow),1979227(reserved)。

original-control窗口bitrate：1021052(firstQualifiedWindow)。

无约束对照实际安装1次，说明新增策略守卫没有把本轮合格自动路径一律禁用。原配置对照发出0张票据，完整窗口与原始策略原因保留；不将诊断配置的触发情况外推为原配置稳定恢复通过。caps/fixed两轮的新帧间隔只对应用户策略切换，不与自动恢复空档直接比较。

原配置在33.563876秒得到首个合格窗1021052bit/s，但41.105379秒已自然升高档，早于第二8秒窗口完成，故零票据符合冻结规则；不修改窗口或带宽要求来制造触发。

原配置哈希 `4e4f256c59465f4a573d6ab1c48f7a7571294638025088d0cddba9325f5032ea`；诊断配置哈希 `9f63acdf1ab0ce92c5565bc3a750478f0c6c5ba76cef88c7e1092cfcd89b01f1`。保持先高后低、有逾期、至少5秒连续缓冲和20秒剩余、双8秒窗/每窗3请求及955000bit/s、源级两次预算和500/1000ms退避。准备最多2秒且受原票据5秒有效期限制。

采集passed仅表示探针完成。策略实际提交、后续持续选择和新帧宽度另行核对；continuityAccepted、physicalOutputVerified、audioSynchronizationVerified仍为false。新帧证据来自AVPlayer像素缓冲与测试纹理接收器，并非物理屏幕实拍；有限采样不能证明物理屏幕、音画/字幕无中断。

## 集中验收与后续

最终iPhone七类171项、macOS六类146项通过，均0失败/0跳过；完整测试树和实际类计数保存。包括DASH loader、Apple session/publication、network byte source、platform services、nonblocking metadata，以及仅iOS现有live reconnect。网络工具116项、benchmark完整发现294项（包含15项台账测试）、镜像/固定历史来源及diff检查通过。无媒体环境的探针不执行真实媒体，四轮媒体另列。未将受影响范围回归冒充完整Dart/Android/全部Apple/独立消费者验收。

13组历史证据3222个清单文件逐一校验未变。本轮生产源码身份仍为 `9fd66d341470a59bbc1eca827c85f52e63b81766ce7a0f361477e1abe7db8064`；采集与最终诊断源码身份单列。构建/运行警告原样保留。

一次独立只读综合复审完成，无阻断问题。复审时核对198个清单文件、181条原始来源记录、8个完整xcresult，bundle成员与原始目录逐文件哈希一致；独立计数iPhone171/macOS146全部通过。采集的14个源码文件与最终内容一致，四轮媒体制品身份一致且自有采集进程均退出。最终清单另包含复审记录、源码绑定和复审后台账校验，见SHA256SUMS与final-verification.json。

仍保留：原配置稳定安全自动恢复、缩短替换新帧空档、真实物理路由断开、完整public-host auto/caps/fixed及清除限制/恢复矩阵、凭据与其他意图竞争、物理音画/字幕连续性、多设备/最低系统、DRM/Dolby授权、外接输出及历史iOS33失败/1skip。旧终末停顿按用户指令维持移出后续待办，不恢复跟踪，历史证据不改。

台账仅补本轮证据和后续行动，102行全部状态保持：67 implemented / 34 partial / 1 unreviewed；69 not_run / 30 external_missing / 3 failed / 0 passed，无新增完整acceptance，releaseReady=false。仅本地提交，不合并、不推送、不打标签、不发布。
