# iOS 诊断恢复候选凭据竞争与提交边界

基线 `7a089625`，本地分支 `codex/abr-recovery`。继续已授权剩余项，采用系统排障/TDD/集中验收。[完整证据](evidence/2026-10-28-ios-credential-race/)保存原始红绿、源码绑定与完整xcresult。不发布。

## 已确认问题与修复

诊断恢复原先直接构造YlPreparedHlsAsset，未传当前播放loader的凭据上下文；候选即使预先准备成功，也可能在旧代理经历跨源剥离后重新向原始资源发送测试凭据。票据同时只绑定item代次与transport revision，凭据状态变化不能直接撤销旧票据。该问题存在于诊断候选路径，不声称生产公开命令存在同样泄漏。

先抽取原逻辑，再用两个原生测试复现：候选上下文身份不相同，代理再次带回已剥离的凭据；凭据版本改变后旧票据仍获准，资格窗口未正确重建。完整red bundle保留两项失败（含所有断言），不能只用编译失败作为复现。

修复让候选沿用当前loader的YlHlsCredentialContext及source请求元数据；Sample/Ticket绑定credentialRevision。revision为该用户Load上下文永久剥离的不同资源数，重复strip不增长，锁保护并发读取与插入。凭据版本变化清除pending/inflight和窗口，但不退还源预算，也不复活旧票据。生产未添加自动恢复策略或安装入口。

采样版本2同时重放transport与credential revision：UInt64、单调、跨版本窗口重新计时、票据事件与发票决策双版本绑定。v2 installed事件还要求credentialCommitAccepted=true。缺字段、倒退、错绑、跨版本窗口和无提交锁证据均拒绝；版本1历史结果可识别但不提升覆盖。诊断只记录数字版本，不记录真实凭据内容；测试使用固定合成凭据。

## 独立复审与提交锁

综合复审发现1个P2：最终authorizes读取revision与实际replaceActiveDash之间仍有后台strip竞争。新增并发红灯在安装闭包内观察到strip提前完成；修复后withUnchangedRevision在同一上下文锁中比较版本并执行短同步提交。版本先变化则拒绝，提交先获锁则完成实际item安装后才允许strip。抛错也释放锁。

该同步闭包仅由受控诊断调用，当前和候选DASH已完成preflight；不做网络等待或上下文重入，回调仅保存诊断状态。现有已加载DASH资源/代理回调取得context锁时不持有安装要取得的资源锁。新增测试在真正backend的makePlayerItem处注入后台strip，验证其不能穿过实际换item。生产上下文新增只读版本和内部同步提交函数，其余生产源码不变。

定向复核确认原P2闭合，此受控诊断调用未发现新增死锁或重入问题。结论不推广到任意生产回调，函数的禁止重入/禁止网络等待约束保留。

## 测试范围与限制

本地组合测试先让真实AVPlayer加载本地MP4到ready，再从独立DASH代理发出实际跨源redirect/return请求；共享上下文变化使准备取消、detach、无候选item返回、源预算仍为1。取消回调直接discard一个DASH准备候选，并验证其takeLoader被拒绝、proxy cancelled=1。另一个提前准备的共享上下文候选代理再次请求同资源，不再发送Authorization/Cookie/显式credential，普通header保留。独立上下文和并发重复strip也有覆盖。

上述测试使用合成带宽发出票据；不冒充真实DASH候选inflight网络请求被撤销、公开Load生命周期或完整public/Dart凭据竞争。当前证明范围是本地组合准备取消、共享代理的凭据继承，以及另一个直接backend测试覆盖的原子item提交。

最终同源码候选：macOS185/185、iPhone210/210，均0失败/0跳过；核对macOS 7类、iPhone 8类的唯一执行身份。复审前macOS183/183和iOS编译结果单独保存，不冒充最终制品。凭据/提交锁定向5/5通过。网络工具124通过，消费者夹具46项中45通过、1历史focused evidence缺失跳过；镜像声明iOS847/macOS891及历史来源检查通过。iPhone起初断开，用户重新连接并解锁后运行上述最终原生矩阵。设备原生测试中有本地媒体与受控网络合约，不等同长素材ABR或物理连续性验收。

准备2秒、票据5秒、双8秒窗口、955000bit/s、最多2次、500/1000ms退避均未改变。本轮不重复长素材；上轮pause/seek两轮到EOF但仅320宽、高档恢复失败，完整保留在既有证据中，没有用本轮合约通过替代。

## 发布台账与剩余项

最终生产源码哈希 745362ff8d58a76ae2fe185ba8b91708b15c04a687f00ef3925363f02b463ba7；源码绑定已更新。

台账只补充本轮诊断证据与后续行动，102行implementation/verification/acceptance状态维持；releaseReady=false。仍保留完整public/Dart凭据竞争、公开Load隔离、同一DASH候选inflight网络取消、原配置稳定自动恢复、暂停/跳转后640高档恢复、替换新帧空档与物理音画/字幕、多设备/最低系统和DRM/Dolby授权等未完成项。旧终末停顿不恢复待办。未合并、推送、打标签或发布。

最终验收仅覆盖本轮受影响原生/工具与凭据合约；生产依赖、公共Pigeon/Dart协议及Android未变，复用基线证据，未声称本轮运行全部Flutter/Android消费者测试。编译/链接和最低系统版本等原始警告完整保留。

台账初次检查因iOS CAP-ABR直接引用增至21而失败，原始失败记录保留于readiness-invalid。保持最多20个直接引用的原结构限制，把较早的[主分支合并记录](2026-10-27-remaining-main-merge.md)改由本报告索引；该证据仍保留在evidence总表与历史文件中，不删除历史、不扩大限制，也不改变任何验收状态。

整理后台账结构检查与15项回归通过；源码匹配，releaseReady=false，发布和性能require-ready均按预期退出1。最终记录独立复核通过。完整7份xcresult与原bundle逐文件校验；17组、4556个历史清单文件未改写。
