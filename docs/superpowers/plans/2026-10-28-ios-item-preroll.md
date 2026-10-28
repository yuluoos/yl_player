# iOS 候选预滚与准备撤销实施计划

基线0464c7bb，沿用用户直接实施及集中验收授权、已连接iPhone开发签名；不发布。以现有同源替换诊断为基础，生产自动策略仍不接入。

- [x] 加入显式asset-preroll模式（原item交接方案因真机崩溃撤销），限定owned managed120秒auto-reload，要求每条原生主采样回显。先保留模式拒绝和原生取消用例红灯。
- [x] 在测试夹具实现候选player ready→精确seek→preroll；静音、禁外接、rate0，仅2秒且不超过原票据到期。每阶段/等待循环检查原意图，失败取消seek/preroll/asset并detach/discard；成功detach后以同asset创建全新item，通过现有makePlayerItem工厂一次性安装，asset身份必须匹配，禁止跨player复用预滚item。主播放器仍执行原精确seek。
- [x] 补齐真实挂起请求撤销、过期、拒绝准备、真实本地媒体预滚/全新item安装，以及两次失败准备/意图作废仍消耗预算的回归。增加pause-during-preparation诊断，在候选ready之后、seek之前撤销首张票据，记录是否真实执行；不把未达到该阶段视为覆盖。
- [x] 原生定向通过后，以同一制品依次normal/preroll/normal/preroll/mid-pause，再原冻结配置normal一轮。每轮120秒，原生140/采集240秒；失败保留并先分析。仅确认有收益且安全后才考虑生产行为修改。
- [x] 最终iPhone/macOS受影响原生与生命周期、network/benchmark、镜像一致性，独立综合复审一次；归档完整原始失败/xcresult/源码制品身份，更新台账但不提升完整能力状态，本地提交。

固定策略：先高后低、有逾期、至少5秒连续缓冲、至少20秒剩余、两个连续8秒窗，每窗至少3请求且955000bit/s，最多2预算、500/1000ms退避。预算不因取消、失败、换item或短暂恢复退回。不修改精确seek或连续性门槛。

边界：预滚成功不保证解码状态可跨player保留，最终seek可能抵消收益；真实屏幕/音画/字幕、旧63.900秒停顿、原配置稳定恢复、物理拔插验证、最低系统和DRM/Dolby资源仍分别记录。已有路由暂停修复与原失败保留。准备中暂停只覆盖明确注入阶段，不能代替所有seek/凭据/约束竞争。

执行修订：真实本地素材用例证实“detach后将预滚item交给第二个AVPlayer”会抛NSInvalidArgumentException；原始崩溃、完整xcresult、代码快照保留，不以延时猜测规避。撤销该交接设计，将模式改名asset-preroll，只共享已预热asset、创建全新item，原精确seek不变。修订后定向真机3项通过，工具回执25项通过。六轮对照均使用修订后的模式；收益尚待采集，不把预热资源当作复用解码器。
