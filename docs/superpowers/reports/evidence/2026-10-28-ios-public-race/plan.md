# iOS public-host 准备期策略竞争实施与验收

基线0ba2a263；继续已授权未完成项，系统排障/TDD/集中验收，本地实施，不发布。

目标：补齐真实恢复候选已ready后，public host设置320上限或固定320低档时的取消/预算/新策略持续输出验证。先实现这两条已有明确契约的竞争路径；暂停/跳转/凭据及生产自动恢复继续保留，不能以本轮替代。

设计：复用诊断auto-reload冻结资格、两次源级预算、500/1000ms退避、2秒准备和5秒票据有效期。新增--public-policy-race，仅接受managed120s、auto-reload、asset-preroll和caps/fixed-during-preparation，不允许public-policy-cycle/direct/startup delay。通过真实YlApplePlayerHost.load加载；候选ready回调允许等待typed public命令完成，然后重新检查原票据、实际item、host已接受策略。public路径不手动作废票据，不调用backend替换；实测状态/身份守卫必须拒绝旧候选。候选仍为测试诊断，生产无新增恢复入口。

文件：canonical YlDashResourceLoaderTests及双平台镜像（探针/异步ready后重验回归）、main_example_tests计数、abr_accesslog.py/test（失败关闭、必须触发首票/命令成功/取消且不安装、source预算不退款、同session、新策略后真实320新帧、EOF）、README、报告/台账。

- [ ] 验证器先红后绿；错误模式、零票据、伪取消、手动作废、旧item仍活跃、策略/新帧不符必须拒绝。
- [ ] 接入public host准备期命令，旧后端诊断路径保持；候选延迟回调必须重新校验资格和期限，任何失败禁止旧候选安装。
- [ ] 同一构建在iPhone零延迟诊断配置执行caps/fixed；原冻结配置记录自然资格结果，不放宽门槛，不把无票据当竞争通过。
- [ ] 最终受影响原生/工具矩阵、一次独立综合复审、完整失败/证据归档、台账hash与未就绪门禁核对、本地提交。

集中复审重点：host命令失败不能被记作取消成功；await期间ticket到期/失效；同session不代表同item；无真实候选ready/无票据不能通过；预算不能退款，后续不得出现意外自动安装；初始和失败记录不得泄露凭据。
