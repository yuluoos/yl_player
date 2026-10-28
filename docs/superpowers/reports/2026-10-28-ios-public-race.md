# iOS public-host 准备期清晰度竞争与候选期限验证

基线`0ba2a263`，本地分支`codex/abr-recovery`。继续已授权剩余项，沿用系统排障/TDD/集中验收；[原始证据](evidence/2026-10-28-ios-public-race/)保留失败、制品/源码绑定及完整xcresult。不发布。

## 本轮范围

新增`--public-policy-race`：仅managed DASH、120秒、auto-reload、asset-preroll及caps/fixed-during-preparation；不允许public-policy-cycle、direct HLS或启动延迟混用。真实YlApplePlayerHost加载，原冻结资格自然发出首票，候选AVPlayer实际ready后调用typed public setVideoConstraints(320)或selectVideoTrack(320低档)。public路径不调用invalidateIntent，不通过backend直接提交策略；实际已接受策略和item身份变化必须使旧候选失效。无生产恢复安装入口，生产源码保持不变。

校验须同时有1次自然预留/发票、1次预算消耗且不退款、候选真实ready、命令成功、同session换item、旧候选cancelled/detached、后续accepted策略正确、命令后所有新帧宽320和既有EOF检查。无票据、仅播到片尾、命令失败、手工作废、未换item、缺新帧或尾帧越过上限均拒绝。最初缺新API红灯，以及遗漏末条主采样后尾帧的2个反例红灯均保留；修复后31项accesslog通过。

## 独立复审发现的期限问题

初版在候选ready后直接await公开命令，等待期间无法检查2秒准备期限。独立复审复现票据29.9秒过期、命令41.8秒才返回，验证器仍接受取消竞争。候选可能持续占用资源，且返回后资格失效会掩盖超期。

原生deadline-red以外部观察者在2.2秒检查资源释放后才允许命令返回，稳定失败：Deadline must detach and cancel while the public command is still pending。Python同时保留超期命令/篡改deadline共4条红灯。

修复将公开命令放入独立任务，候选继续轮询原期限/资格，超期立即pause、取消preroll/seek、detach并取消asset/loader。返回的任务由调用者在记录候选清理时间及结果后等待；不因诊断候选过期撤销用户命令，晚到命令不能改写已确定的候选结果。事件保存原warmupDeadline=min(warmupStart+2,ticketDue+5)；校验器重新计算期限，并要求命令完成和候选清理均未超期。未扩大窗口、期限、预算或退避。

定向复审确认该P2闭合；未发现其它未解决P1/P2。原生期限红灯与修复后178项macOS、31项Python定向绿灯均保留。它是诊断资源/验收可信度修复，不能包装成生产自动恢复修复。

## 真机结果

设备iPhone16/iPhone17,3，iOS27.2(24B119)，已授权开发签名。原配置哈希4e4f256c59465f4a573d6ab1c48f7a7571294638025088d0cddba9325f5032ea；独立零延迟诊断配置9f63acdf1ab0ce92c5565bc3a750478f0c6c5ba76cef88c7e1092cfcd89b01f1，均不变。素材120秒、原生循环140秒、采集240秒不变。

复审前caps/fixed按初版校验分别到120.026553349/120.015151587秒，1票、命令提交、item变化、候选取消、后续320帧均存在。这两轮没有新增deadline字段，不据此声称通过最终期限验收；完整原始passed值不改写。

同批原配置对照在52.537650秒willResignActive、54.112853秒didEnterBackground，末位置52.256574143、rate0、host failed，未到片尾，整轮失败保留。自然票据0；33.457962秒首个合格窗1334768bit/s，39.934363秒已自然恢复640高档，间隔6.476401秒，早于第二个8秒窗口，故零票据符合冻结规则；不能把这轮用作完整前台原配置对照或竞争通过，也不据此认定产品后台恢复根因。最终复测需要用户确认连续前台窗口。

用户再次确认连续前台后，期限修复后的同一制品完成以下两轮。系统前后台/音频事件均为空，原配置被中断的失败仍独立保留。

| 最终运行 | 结果 / 片尾位置（秒） | 源预算 | 策略后主采样 / 新帧 |
| --- | --- | --- | --- |
| deadline-fixed-caps | 通过 / 120.022996966 | 1 | 322 / 1991 |
| deadline-fixed-fixed | 通过 / 120.031176138 | 1 | 322 / 1993 |

deadline-fixed-caps：票据due=37.193374，准备期限=39.352898，公开命令完成=37.480737，候选清理完成=37.496195秒。公开命令成功、同session换item、未手动作废票据；候选cancelled/detached，不安装新候选，后续新帧只提交320宽。
用户策略切换新帧间隔[102.614]ms，texture clear=[1]；不作为自动恢复空档改善证据。

deadline-fixed-fixed：票据due=37.067063，准备期限=39.226491，公开命令完成=37.377575，候选清理完成=37.406374秒。公开命令成功、同session换item、未手动作废票据；候选cancelled/detached，不安装新候选，后续新帧只提交320宽。
用户策略切换新帧间隔[122.947]ms，texture clear=[1]；不作为自动恢复空档改善证据。

采集不授予capabilityAccepted、continuityAccepted或physicalOutputVerified。测试纹理接收器的新帧不是物理屏幕/音画/字幕连续性证据。策略切换的间隔不等同自动恢复间隔，不能宣称缩短。

## 统一验收与台账

最终期限修复候选：iPhone203/203、macOS178/178，均0失败/0跳过；核对8个选定类的唯一执行身份。复审前203/178结果另存，不混同源码版本。网络工具120通过，accesslog定向31通过；消费者夹具46项中45通过、1历史focused evidence缺失跳过。镜像声明iOS840/macOS884与固定历史来源检查通过，声明数不替代执行数。生产、依赖与benchmark工具未变，复用基线已有294项benchmark及core/API证据；未冒充全Flutter/Android/全部Apple消费者验收。

生产源码哈希仍为41b62a909e274818876d5b08c0999f476d0874ef131ea2a3db5bea86830441c2；仅诊断夹具、镜像、工具、文档/台账改变。两个profile及冻结策略数值不变。台账补证据、绑定和后续行动；102行状态保持，releaseReady=false，require-ready仍拒绝发布。

最终记录独立核对通过；完整原始失败、复审前/后源码身份已归档，10份完整xcresult与原bundle逐文件哈希核对一致。历史15组、4021个清单文件已确认未改写。原生编译/运行警告原样保存。最终台账结构检查通过，发布就绪与性能阈值的require-ready均按预期返回1，拒绝发布；15项台账回归通过。

仍保留：public pause/seek与凭据竞争、原配置稳定安全自动恢复、替换新帧空档、真实路由与前后台恢复、Dart链路、物理音画/字幕、多设备最低系统及DRM/Dolby授权等外部资源缺口。旧终末停顿不恢复待办。不合并、不推送、不打标签、不发布。
