# POSIX54后高档重试与温和带宽对照

基线e4c93978，承接[错误来源诊断](2026-10-29-loopback-error-source.md)。用户先授权三轮约9分钟前台采集，又授权两轮约6分钟补充对照。沿用系统排障、测试驱动和集中验收；不增加预算、不退款、不放宽门槛、不发布。

## 实施

修正source0注释为“无已记录取消错误”，解决上轮P3；它仍可能伴随outcome=sendFailed，不代表整个交换无错误。生产Swift仅此注释变化，播放器行为没有修改。

新增rendition_retry.py诊断及3项回归：旧临时error-analysis按服务器请求开始时间筛“later”会包含报错时已在途的请求。本工具先要求v7完整关联和既有严格代理证据，再以同一设备uptime比较候选admission与失败downstreamTerminal，只有严格晚于终止的接纳才记为新尝试；在途/同时刻请求单列。同一proxy内同资源重试、同档请求及其他proxy生命周期请求分开；其他proxy保留proxyID+requestID，不据新的proxy请求声称原item自然重试。服务器时间整体平移不改变结果。缺关联、旧版缺错误来源或成功事务指标不完整均不能被当作“没有重试”。这只修复分析口径，不改变任何媒体验收器或重试行为。

新增功能先红后绿：隔离后的3测试均因功能缺失失败，完成后3/3通过；另保留跨代理请求身份断言的红绿。最初测试模块导入TestCase类额外发现既有用例，改为模块导入后只运行本模块3项；原始日志不覆盖。最终网络工具206/206，消费者45通过/1既有focused历史证据缺失跳过；注册883/927来源检查通过，不能等同全部执行。

## 新制品与原生验收

旧/tmp构建和原始临时目录已清理；本轮从仓库重新构建，历史核对直接读取归档，没有依赖不存在的旧制品。新iPhone16/iOS27.2选定矩阵256/256、macOS231/231，无失败/跳过，身份逐项绑定。真实RST探针、半关闭完整正文、截止回收、预算和竞争合约均在选定矩阵内。冻结438份构建输入，随后仅新增2份宿主Python诊断/测试文件，最终440份输入；438份构建输入无改动，307份iPhone制品逐项绑定全部采集回执。编译/运行警告和设备诊断原样保留。

预算2、955000bps、双8秒/每窗至少3请求、缓冲5秒/剩余20秒、500/1000ms退避、2秒准备/5秒票据全部不变。原生恢复策略、媒体/预算/连续性门槛文件与基线逐字节相同。每轮120秒自有DASH、close连接、manifest-only准备；budget前缀均公开pause-resume使第一次预约失效且不退款，要求实际生产安装和严格预算专项。

## 五轮设计与实际结果

原对照第二次故障60–65秒：50k B/s基准与75k B/s温和控制只有该速率不同。正常重复恢复使用原停流profile且不公开暂停，不是该对照的单变量成员。首50k轮安装较晚，第二故障阶段尚未恢复高档，最终640仍未通过再次降档预算专项。75k轮未再次降档，同样不能冒充预算耗尽后的恢复通过。两轮均原样保留为严格失败。

用户追加授权后，新增独立profile将两者第二阶段统一后移至70–75秒，仍只比较50k/75k速率。此为补充诊断，未覆盖原配置失败、未改变验收门槛；是否足以形成高档后再次低档由实际帧和请求证明，不能先验假定。所有媒体清单及资产指纹相同，配置只控制变量，不消除实际预约/安装时刻的运行变异。

| 场景 | 预约/安装 | 末次位置/宽度/完成 | 替换新帧间隔ms | 全程最大发布新帧间隔ms | 预算专项 | 严格/复算 |
| --- | --- | --- | --- | --- | --- | --- |
| budget-throttle | 2/1 | 120.019365/640/True | 1097.976 | 2689.794 | 未建立/失败 | False/False |
| budget-mild | 2/1 | 120.023583/640/True | 310.930 | 2032.275 | 未建立/失败 | False/False |
| normal | 2/2 | 120.028929/640/True | 279.322/310.060 | 364.575 | 不适用 | False/False |
| budget-late-throttle | 2/1 | 51.099435/0/False |  | 2079.932 | 未建立/失败 | False/False |
| budget-late-mild | 2/1 | 120.012937/640/True | 221.621 | 2069.563 | 未建立/失败 | False/False |

严格0/5，独立复算0/5。四轮原生退出0，一轮退出65；到EOF或最终高档均不能单独替代包含预算场景的严格结果。

### budget-throttle

原回执错误=["ValueError"]；重算错误=[{"check": "budget", "error": "invalid repeated downshift budget evidence"}]。信号=[]。最后安装61.584646625007736秒、其后首高档73.71441225000308秒、再次低档None秒、再高档None秒。尾90秒后宽度=[640]，全部采样无应用限档。

代理375条，取消1、发送失败2、缺metrics 0、空事务0、多事务0、未关联0。第二故障阶段及以后已关联高档非成功请求数=0，最后安装后错误事件数取值=[0]。服务器恢复时点65000ms后高档请求67个（仅服务器时钟内统计）。

### budget-mild

原回执错误=["ValueError"]；重算错误=[{"check": "budget", "error": "invalid repeated downshift budget evidence"}]。信号=[]。最后安装54.327597708339454秒、其后首高档55.43688945833128秒、再次低档None秒、再高档None秒。尾90秒后宽度=[640]，全部采样无应用限档。

代理377条，取消1、发送失败4、缺metrics 0、空事务0、多事务0、未关联0。第二故障阶段及以后已关联高档非成功请求数=0，最后安装后错误事件数取值=[0]。服务器恢复时点65000ms后高档请求60个（仅服务器时钟内统计）。

POSIX54高档proxy 97C35E8A-7027-4130-9690-73BFAD50F379/request57、入口1：终止后同proxy新高档[]、同资源重试[]；当时在途/同时刻[]；其他proxy后续高档85条，完整身份见retry-analysis.json。

### normal

原回执错误=["proxy successful transaction metrics incomplete"]；重算错误=[{"check": "proxy", "error": "proxy successful transaction metrics incomplete"}]。信号=[]。最后安装95.8309759166732秒、其后首高档97.90427650000493秒、再次低档None秒、再高档None秒。尾90秒后宽度=[320, 640]，全部采样无应用限档。

正常重复恢复高低高与尾段证明={"firstHigh": 37.43805804167641, "secondLow": 69.43890433333581, "secondInstall": 95.8309759166732, "secondHigh": 97.90427650000493, "highTailSeconds": 23.96681174999685, "stableHighTail": true, "capabilityAccepted": false}。

代理421条，取消2、发送失败6、缺metrics 0、空事务0、多事务1、未关联0。第二故障阶段及以后已关联高档非成功请求数=1，最后安装后错误事件数取值=[0]。服务器恢复时点65000ms后高档请求30个（仅服务器时钟内统计）。

本轮重试诊断拒绝输出无重试结论：proxy successful transaction metrics incomplete；空缺不表示0次重试。

### budget-late-throttle

原回执错误=["proxy request correlation incomplete", "ValueError"]；重算错误=[{"check": "production", "error": "invalid production recovery evidence"}, {"check": "playback", "error": "incomplete or invalid ABR observation"}, {"check": "budget", "error": "invalid repeated downshift budget evidence"}, {"check": "proxy", "error": "proxy request correlation incomplete"}, {"check": "native", "error": "65"}]。信号=[]。最后安装54.094665666663786秒、其后首高档None秒、再次低档None秒、再高档None秒。尾90秒后宽度=[]，全部采样无应用限档。

代理226条，取消8、发送失败4、缺metrics 0、空事务0、多事务0、未关联51。第二故障阶段及以后已关联高档非成功请求数=0，最后安装后错误事件数取值=[0, 2, 4, 6, 7, 8, 10, 12, 13]。服务器恢复时点75000ms后高档请求0个（仅服务器时钟内统计）。

本轮重试诊断拒绝输出无重试结论：retry evidence requires complete request correlation；空缺不表示0次重试。

### budget-late-mild

原回执错误=["ValueError"]；重算错误=[{"check": "budget", "error": "invalid repeated downshift budget evidence"}]。信号=[]。最后安装93.83432049999828秒、其后首高档95.52350120834308秒、再次低档None秒、再高档None秒。尾90秒后宽度=[320, 640]，全部采样无应用限档。

代理376条，取消1、发送失败1、缺metrics 0、空事务0、多事务0、未关联0。第二故障阶段及以后已关联高档非成功请求数=0，最后安装后错误事件数取值=[0]。服务器恢复时点75000ms后高档请求35个（仅服务器时钟内统计）。

POSIX54高档proxy 82142FB3-7E8D-4EA4-9E89-527D768582F2/request57、入口1：终止后同proxy新高档[]、同资源重试[]；当时在途/同时刻[]；其他proxy后续高档35条，完整身份见retry-analysis.json。

## 补测失败的进一步定位

budget-late-throttle原生退出65，最后位置51.099435秒、width=0、completed=false；第2次预约在54.094666秒安装后，代际1没有发布任何新帧。末次发布54.083785秒至观测结束99.420221秒持续45.336436秒无新帧，不能用此前2.080秒的最大已发布帧间隔或空replacementBoundaries掩盖。原生断言记录AVPlayerItemStatus.failed，生产恢复/播放/预算/关联全部失败。

导出的StandardOutputAndStandardError.txt显示到夹具上游192.168.50.196:56959的连接建立失败1:60、URLSession -1001、HTTP load 0/0 bytes；随后的map访问日志报告No response for map in 1s。51条代理任务没有服务器关联，其Foundation事务请求/响应字节计数均0。服务器177个已接纳连接均有已解析请求且handlerEnded，没有未记录请求；末次服务器请求在profile 51.956秒结束，早于计划70秒的第二降速。该证据支持这轮存在上游连接超时，区别于回环POSIX54；仍不能判定Wi-Fi/主机/服务器接纳路径的具体内部失效点，也不能以0计数证明未发包。没有抓包或连接探针交叉验证，不把它归因于70–75秒带宽控制、预算策略或此前回环错误。

此次xcresult的console log接口返回No console log available，原失败保留；改用export diagnostics成功取得原生标准输出。该当前失败作为替换后上游连接超时及无新帧证据保留，不复活此前已删除的旧终末停顿待办。

budget-late-mild最后安装实际晚至93.834320秒，首高档95.523501秒；70–75秒阶段没有高档请求，末次安装后无再次低档。后移10秒仍未建立目标预算场景，不能将此轮最终640称作预算耗尽后的再次恢复。后续需要先确保有效高档基线，再设计单变量故障对照；不能继续仅用固定延时假定场景已成立。

## 原因边界、历史及未完成项

新增统计区分了“已有请求”“错误后的新尝试”和“替换后的请求”。不依据服务器开始时间与设备终止时间直接相减；也不把新proxy流量直接等同item的自然恢复。POSIX54说明本次记录的连接重置错误入口，不暴露AVPlayer决定取消/再尝试的内部算法；当前没有证据给出固定2秒超时、penalty时长或可安全重置私有状态的结论。Apple公开HLS说明只提供一般自适应行为；查询到的社区问题未当作本程序或该OS版本的证明，见research-notes.json。

75k控制若保持高档且没有再次降档，只能说明该轮没有触发目标故障，不能证明发生POSIX54后能够自然恢复。50k的首轮未形成再次降档同样是失败场景，不能用最终640消除上轮真实320失败。所有失败保持严格结论。没有确认安全的播放行为修复，因此未增加第三次替换、未退款、未强制高档、未改原预算或验收器。

发布层新帧间隔是诊断数据；含公开暂停的全程最大间隔不能当作替换瞬间空档。物理屏幕和音频未经校准采集，continuityAccepted、audioSynchronizationVerified、physicalOutputVerified、capabilityAccepted仍false。继续保留高档自然恢复与稳定性、更多故障/生命周期竞争、历史双事务/macOS就绪超时、设备/最低系统/实际网络/授权素材及物理音画缺口；不重建已删除的旧终末停顿待办。

历史双事务旧v2缺字节计数和响应日期不补造；六轮归档逐原始哈希读取重算仍3通过/3失败。新制品强制上游首次关闭合约两平台仍出现2事务，不能据受控诱因认定历史内部原因。本轮normal自然复现一次成功双事务：proxy request4、服务器仅request143解析一次；第一事务Foundation报告请求头309字节、响应头/体均0且无响应日期，第二事务完整8391字节，整体taskOutcome=0、正文完整、无重定向、两事务reused=0。严格指标门槛保持失败。新v3补齐了这次缺响应的字节事实，但不证明历史v2缺失值也为0，不证明网络真实发包/服务器接收次数，也尚不能定位Foundation为何重试。详见new-double-transaction.json。

## 台账与归档

49组10273条历史哈希与基线e4c93978一致。102行implementation/verification/acceptance不升级，仅更新生产注释指纹、报告引用和下一步；保留20条唯一直接引用及历史全局定义。结构/阈值检查和15项台账回归通过，sourceMatches=true、releaseReady=false，require-ready退出1。

[独立综合复审](evidence/2026-10-29-reset-retry-control/review-final.md)与[完整证据](evidence/2026-10-29-reset-retry-control/README.md)保留全部原始失败、红绿、两平台矩阵、五轮媒体结果包、参数差异、请求/帧/策略/错误、源与制品身份及历史核对。未推送、合并或发布。
