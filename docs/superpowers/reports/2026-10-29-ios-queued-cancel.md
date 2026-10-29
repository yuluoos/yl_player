# iOS 快速取消未关联的受控复现与恢复稳定性

基线c9b93882，承接[取消来源与四轮对照](2026-10-29-ios-fast-cancel.md)。用户已授权准备后约12–15分钟前台采集。沿用系统排障及集中验收，保留全部原始失败、设备/授权缺口和验收门槛，不发布。

## 已补齐：真实网络的可重复取消路径

新增testQueuedProxyCancellationNeverReachesServerOrPoisonsNextRequest，三份规范/示例测试保持一致。使用已有sessionFactory入口建立真实Foundation URLSession，仅测试将httpMaximumConnectionsPerHost设为1；自有HTTP/1.1服务器占住第一个请求。受控服务器与代理都运行在测试设备回环地址；长素材测试另用Mac局域网服务器，二者网络条件不混同。第二个下游NWConnection发送完整GET和EOF，代理实际接入并创建任务，随后观察EOF并取消任务；上游尚未获得连接名额，因此没有对应的已解析服务器请求。

用例等待取消任务的真实完成和诊断交付后才释放首请求，再发/after并成功读取内容。服务器最后只记录/held和/after，取消的correlationID不在服务器记录中，没有释放名额后晚发/cancelled，activeTasks/activeRequestTraces归零，未把取消报告成上游故障。原始trace及服务器解析路径/correlationID保存为XCTAttachment，完整xcresult和导出的原始附件一起归档。

Apple将该配置定义为每会话HTTP/1.1连接上限，HTTP/2及以后不受它控制；本测试使用明文自有HTTP/1.1。生产没有设置此单名额限制。[Apple httpMaximumConnectionsPerHost](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/httpmaximumconnectionsperhost)

| 执行 | 代理接入至下游关闭ms | 取消来源 | Foundation事务数 | 对应服务器请求 |
| --- | --- | --- | --- | --- |
| queued-first / My Mac | 1032.323250 | 2（下游EOF） | 1 | 无已解析记录 |
| queued-fast / My Mac | 0.088208 | 2（下游EOF） | 0 | 无已解析记录 |
| macos-final / My Mac | 0.098208 | 2（下游EOF） | 0 | 无已解析记录 |
| ios-final / iPhone | 0.105625 | 2（下游EOF） | 0 | 无已解析记录 |

queued-first为首轮探索：通过predicate等待接入导致约1秒等待；一条事务只有fetch开始，fetchToRequestSeconds的state=2（缺requestStart），其他请求/响应日期缺失，与历史失败的缺失组合相同。随后移除测试轮询，GET和EOF连续发送，得到亚毫秒接入后取消，Foundation尚无事务。首次探索源码片段、日志及附件保留；最终macOS/iPhone矩阵使用连续发送版本。测试没有新增延迟或生产日志点，不靠修改传输行为构造媒体通过。

这里证明了一条真实机制：代理接入并不等于已发出HTTP请求；等待上游名额的任务可以因下游EOF而取消，并保留一条未关联诊断。它解释了这种日志形态如何产生，却不能证明历史AVPlayer那两条3.183/4.411ms记录也由连接名额竞争导致。历史实际名额占用和AVPlayer内部取消决策尚无证据。无已解析请求也不等于网络层绝无字节；不作此扩大推断。

原解析门槛未改。reproduction-analysis.json用附件中真实服务器解析顺序的本地序号做格式适配检查（不是服务器分配ID，也不是媒体验收回执），v5原解析器仍给出fullyCorrelated=false和proxy request correlation incomplete。受控复现测试通过表示正确捕获该现象，不把它改成关联通过，不删取消记录。

没有确认新的生产行为缺陷，因此本轮只补测试、注册表和证据，不改生产网络、取消/恢复策略或验收工具。新增的是特征与回归测试，首轮即通过，不虚构修复前红测或生产修复。

## 集中测试与输入绑定

网络工具190/190通过；消费者46项中45通过、1项既有历史focused证据缺失跳过。iPhone完整相关原生250/250、macOS225/225通过，新增一项真实取消用例；规范源码身份总数iOS877/macOS921，不能当实际执行数量。首轮探索与连续发送定向各1项通过，均保留完整xcresult。iOS devicectl部分诊断包及编译警告原样保留，不宣称零警告。

438份输入冻结，307份iPhone制品指纹四轮相同，采集前后检查一致。生产源码指纹与c9b93882完全相同；新构建的是包含新增测试的制品，生产未改。本轮未重跑无改动的Dart/Android全矩阵。独立代码复审无P1/P2，确认真实网络、取消先于释放名额、后续请求及清理断言，限制条件纳入报告。

## 四轮最终制品长素材

original/original-repeat保持原down-and-recover-v1：0秒500000B/s+40ms、10秒50000B/s+200ms、25秒500000B/s+40ms。normal/normal-repeat保持repeat-stall-budget-diagnostic-v1：0秒500000B/s+40ms、10秒停流、15秒2000000B/s+0ms、60–65秒再次停流、之后2000000B/s+0ms。120秒自有素材，close模式。原配置不强制人为安装，诊断配置必须真实安装。

955000bps、双8秒窗口/每窗口3请求、缓冲5秒/剩余20秒、每源2次预算、500/1000ms退避、准备2秒/票据5秒均未改；所有代理请求仍必须关联，成功请求全部事务核心区间仍要求完整。

| 场景 | 真实安装数 | 第二次高档尾部秒 | EOF位置秒/宽度 | 替换边界新帧间隔ms | 全程最大新帧间隔ms | 严格回执 |
| --- | --- | --- | --- | --- | --- | --- |
| normal | 2 | 34.653 | 120.019321/640 | 104.485/138.792 | 350.617 | 失败 |
| original | 0 | 无第二次安装 | 120.024254/640 | 无替换 | 1351.807 | 通过 |
| normal-repeat | 2 | 34.078 | 120.029531/640 | 103.548/137.080 | 327.367 | 通过 |
| original-repeat | 0 | 无第二次安装 | 120.024732/640 | 无替换 | 1312.506 | 通过 |

严格回执3/4，独立重算3/4。原生媒体探针结果、所有错误和信号原样保留。

- normal：nativeExitCode=0；0.480秒/320宽 → 4.796秒/640宽 → 20.784秒/320宽 → 37.928秒/640宽 → 69.085秒/320宽 → 86.712秒/640宽；预约/票据=2/2；严格错误=["proxy request correlation incomplete"]。

- normal-repeat：nativeExitCode=0；0.541秒/320宽 → 4.831秒/640宽 → 16.815秒/320宽 → 34.444秒/640宽 → 69.057秒/320宽 → 87.212秒/640宽；预约/票据=2/2；严格错误=[]。

- original：nativeExitCode=0；0.534秒/640宽 → 24.124秒/320宽 → 40.987秒/640宽；预约/票据=0/0；严格错误=[]。

- original-repeat：nativeExitCode=0；0.518秒/320宽 → 4.797秒/640宽 → 24.076秒/320宽 → 39.987秒/640宽；预约/票据=0/0；严格错误=[]。

两次安装的证明要求第一次安装后高档、再次低档、第二次安装后的新generation高档顺序成立；attempts计数不能代替此顺序。原配置自然高档不计自动安装覆盖。新帧间隔是发布层采样，未改算法，不能把轮次差异解释成优化。物理屏幕/音频资源仍缺，continuityAccepted、physicalOutputVerified、audioSynchronizationVerified、capabilityAccepted全部false。

## 媒体取消日志与未闭合项

normal：proxy=409，取消=16，cancelCause分布={"2": 16}，未关联取消=1，服务器接入/解析=410/410。

未关联requestID=63，cancelCause=2，taskOutcome=1，接入至关闭11.511ms，邻近播放采样={"beforeElapsed": 12.560516375000589, "afterElapsed": 12.820787583339552}，位于首次安装前=True。详见原始trace和cancellation-analysis.json。

normal-repeat：proxy=416，取消=14，cancelCause分布={"2": 13, "1": 1}，未关联取消=0，服务器接入/解析=418/418。

original：proxy=339，取消=7，cancelCause分布={"2": 7}，未关联取消=0，服务器接入/解析=341/341。

original-repeat：proxy=344，取消=6，cancelCause分布={"2": 6}，未关联取消=0，服务器接入/解析=346/346。

合计1508条proxy、43条取消；非完整metrics=30条、完全缺失metrics=0条、不完整成功事务=0条、双事务记录=0条。非空指标不等于完整，不改历史判断。

本轮normal在第一次安装之前复现未关联requestID63，来源是下游EOF，接入至关闭11.511ms；只有fetch开始、无requestStart，一条事务、无协议标识/无复用，body/send均0。服务器410个接入均解析，无拒绝或遗漏，未出现该correlationID。诊断证据把问题定位到下游EOF触发取消、HTTP请求开始尚未被记录的阶段，不支持“替换清理导致”或“服务器解析日志丢行”的解释。

failure-cause-analysis.json还重建同一proxy任务的寿命区间：该请求接入时只有自身尚未完成，前3个下游EOF分别早于其终止约21.153/17.286/15.398ms。没有记录到其他未完成代理任务占满名额，所以不能把受控单名额测试直接认作此次媒体的确切诱因。已完成任务可能仍有Foundation内部连接收尾；当前日志不能测得真实连接名额状态，也不能说明AVPlayer为何连续关闭这些请求。原始失败仍严格失败，不将定位到阶段等同全部根因闭合。

受控测试的排队条件与原始媒体运行分开保存，不能把测试夹具根因移植到历史失败。历史两条缺取消来源字段，也无法追补；先前时间对齐已显示其早于第一次替换。本轮实际媒体出现的带来源未关联记录逐条保留；仍需Foundation实际连接占用与AVPlayer内部取消触发证据，历史双事务确切诱因也未闭合。用户不再保留的旧终末停顿不恢复为待办。

## 归档和发布台账

[完整证据](evidence/2026-10-29-ios-queued-cancel/README.md)包含8个完整xcresult（两次受控定向、iPhone/macOS矩阵、四轮媒体）、原始附件、完整原始帧/策略/事务/服务器记录、身份及复审核验。所有本轮失败与历史失败均保留，不选择性删除。

历史37组8391条哈希逐项核对，与c9b93882一致。生产源码指纹仍为43dafc0b10bc7b2419b2373398d37a8787e2010da8d1fd8e1b55627c30bc1ac5；102行implementation/verification/acceptance不提升。全局旧evidence定义及报告链保留，CAP-ABR/iOS的20个直接引用上限不变，最近引用由上轮报告轮替为本报告，本报告开头链接上轮。

台账结构、15项回归、性能注册表及diff检查通过，sourceMatches=true、releaseReady=false，两个--require-ready按未满足条件退出1。不发布、不推送、不合并。

未完成仍包括：实际生产网络及更多轮次/设备稳定性、AVPlayer快速取消的历史确切触发条件和严格关联、历史双事务、预算耗尽后的自然高档机制、更多提交后故障/生命周期竞争、历史macOS连接就绪超时诱因；物理音画、更多设备/最低系统和授权媒体等资源缺口。当前批次补齐了可复现机制及新制品验证，没有授予整体ABR/连续性验收。
