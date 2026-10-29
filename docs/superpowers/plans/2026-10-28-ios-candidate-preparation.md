# iOS 候选元数据准备与原配置排查计划

基线199ac8a7，现有codex/abr-recovery隔离分支。沿用用户要求的集中验收、原门槛和本地真机签名授权；不发布。实施方式沿用本会话直接实施，最终一次独立综合复审。

目标：结合代理边界继续复现原终末停顿，验证在旧item持续播放时预加载候选资源的playable元数据是否能安全缩短新帧空档。该方案是诊断实验；只有证据确认才考虑生产改动。生产自动策略仍不接入。

- [x] 原配置down-and-recover-v1三轮auto；使用199ac8a7现有制品和边界观测。失败即保留并先分析，不把未执行试验记成失败或通过。
- [x] tool/playback_network/abr_accesslog.py增加显式candidate-preparation选择及原生回显校验；test_abr_accesslog.py先写红灯。默认manifest-only保持历史兼容；asset-metadata（原计划名asset-playable，修订见后）仅允许120秒managed auto-reload。
- [x] RunnerTests/YlDashResourceLoaderTests.swift诊断夹具为asset-metadata候选异步加载playable/tracks/duration元数据（原计划仅playable，修订见后），最多等待2秒且不超过现有ticket到期；失败取消asset并discard，消耗的预算不退。记录准备耗时、旧item身份/帧/播放位置；保留全部原票据复查与精确seek。同步iOS/macOS镜像。
- [x] 单独既有zero-latency诊断配置依次normal、warm、normal、warm，再warm pause-first。每轮120秒，原生140/采集240秒上限不变；任何能力/连续性结果不自动改通过。若原配置满足触发条件，可追加一轮原配置warm，最多一轮。
- [x] 集中受影响工具与Apple原生测试、独立复审、原始失败及新旧源码/制品/配置归档、更新发布台账。源清单/报告引用更新不提高任何完整验收状态。

固定门槛：先高后低、有逾期、buffer>=5秒、remaining>=20秒、连续两次8秒窗口、每窗>=3新请求、>=955000bit/s、最多2预算、500/1000ms退避；不变。元数据预加载不伪造带宽，不把旧纹理当新帧。

重点复审：旧制品忽略新选项不能假通过；候选超时/失败释放；暂停后不得复活票据；元数据准备不能冒充解码预热；新日志和旧失败必须保留。

定向实验修订（媒体对照前）：进行中加载回归发现仅playable会直接loaded而不触发资源读取；原失败及活动记录保留。因此候选选项改为asset-metadata，同时等待playable/tracks/duration，保持2秒上限、票据复查和零容忍seek不变。该结果不计作播放改善。

执行结果：原配置三轮均EOF，零票据，因此有条件追加的原配置warm未执行；按预登记完成五轮诊断对照。元数据预加载没有改善新帧空档证据，保持显式诊断选项，不改生产代码。两次预算、500/1000ms退避和准备前暂停撤销已观测；加载中竞争和物理连续性仍未验收。最终iPhone/macOS各131、network111、benchmark294通过。独立复审无阻断；本轮有限实验、证据归档和台账核对收尾，整体恢复验收仍未完成。详见同日候选准备报告。
