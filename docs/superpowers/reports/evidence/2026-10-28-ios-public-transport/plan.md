# iOS public-host 暂停/跳转准备期竞争

基线73f50a0d，继续已授权剩余项；系统排障/TDD/集中验收，本地提交，不发布。

目标：补齐真实候选ready期间公开pause/seek的竞争验证，源预算不退款，旧票据不能因同item或恢复播放而复活。

实现：复用coordinator已有restorationIntentRevision，通过internal只读属性供host读取；该既有计数在确认pause/seek后递增，不添加Pigeon接口或生产自动恢复入口。诊断Sample/Ticket绑定该版本，资格在版本变更后重建，预算保留。真实public命令直接调用，不手动invalidateIntent。暂停后保持2秒并通过public play恢复；跳转前进1000ms，必须看到实际新帧落到目标并持续推进。准备2秒/票据5秒/8秒双窗/955000bit/s/预算2/500,1000ms退避不变。

- [ ] 同item版本变化、无效命令、暂停后恢复、预算不退款的定向红绿；readonly属性和镜像同步。
- [ ] public-policy-race扩展pause/seek，单独严格验证暂停稳定、显式恢复、seek目标、新帧和原期限；禁止把caps/fixed旧语义放宽。
- [ ] 同制品iPhone两轮受控竞争及受影响原生/工具矩阵，保留原失败/设备条件缺口。
- [ ] 一次独立综合复审及定向修复复核，完整归档、台账与未就绪门禁、本地提交。

复审重点：无效命令不得改变权威版本；同item forward/back seek与pause/resume不能复活旧票据；暂停期间位置与意图稳定、不得自行播放；异步seek ack不冒充实际落点；后续新票据仍受同源预算/原期限约束；凭据竞争及生产自动恢复不以本轮代替。
