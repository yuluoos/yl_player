# 回环错误来源区分与预算耗尽恢复验证

基线6b468200，承接[预算耗尽后停留低档对照](2026-10-29-budget-low-cause.md)。用户授权新制品两轮约6分钟前台采集；沿用系统排障、测试驱动、集中验收与独立综合复审。未增加预算、放宽门槛或发布。

## 实施与边界

上轮cancelCause=3合并了连接失败、请求头接收错误和已接纳请求监视接收错误，无法定位入口。本轮只补诊断：HLS代理保持取消/回收语义，v7新增cancelSource（0无已记录取消错误、1 state.failed、2请求头receive、3已接纳请求monitor receive）、cancelErrorDomain（0无、1 POSIX、2 DNS、3 TLS、4未知）和Int32有符号cancelErrorCode。不输出URL、凭据、错误文本、IP或原始日期。仅显式DEBUG捕获记录；非诊断资源释放、半关闭支持和独立截止计时器不变。

trace的第一次终止冻结来源，晚到的另一错误/发送回调和任务完成不会改写；任务仍等待Foundation指标收尾。这里的第一次是trace记录的先后，不是底层事件的绝对物理顺序。头部解析错误若发生在请求接纳前，不存在请求trace，本轮不伪造它；source0还包括outcome已另行标记的发送失败，不表示整次交换没有错误。

严格解析器支持v7并拒绝缺字段、伪造枚举、布尔/浮点/越界错误码、与取消原因矛盾的字段；DNS/TLS负数不会被非负时间校验误拒。v1–v6保持兼容，旧版来源与错误码输出null，禁止反推。当前采集与两个诊断CLI同步升级，成功事务完整性、服务器关联、预算和连续性门槛未降低。

恢复预算仍2，不退款或绕过第三次预约；955000bps、双8秒且每窗至少3请求、缓冲5秒/剩余20秒、500/1000ms退避、准备2秒/票据5秒全部不变。没有强制高档或额外替换。

## 红绿与集中原生验收

先给既有真实取消测试补v7/字段断言：旧实现原生退出65、1失败，缺字段/版本证据保留。解析器新增用例先遇旧版拒绝v7的两处ValueError；首次实现后旧“未来版本7拒绝”断言失败，明确升级未来版本为8，失败日志保留。最终边界23/23，网络工具203/203，消费者45通过/1既有历史focused证据缺失跳过。新注册用例883/927，不能冒充全部执行。

最终新制品iPhone16/iOS27.2选定原生矩阵256/256、macOS231/231，无失败/跳过，执行身份逐项绑定。新增真实SO_LINGER重置探针两平台均记录source3/POSIX54（ECONNRESET），并验证连接、任务、截止计时器归零；允许系统以state.failed或monitor receive先报错，未硬编码回调先后。新增映射冻结用例覆盖POSIX/DNS/TLS/未知映射及晚到错误、正文、任务完成不得覆盖首记录；晚到发送由既有testProxyRequestTimingSealsCancellationAndIgnoresLateSendCompletion验证。既有半关闭完整正文、排队及完整断开/不读取客户端有界回收继续通过。

原生构建/运行中的既有Swift并发、弃用、链接目标和诊断采集警告原样保存；macOS日志还含“command failed with exit code 0”编译诊断，最终矩阵和构建退出0、实际231项均通过，不宣称零警告。iOS devicectl诊断采集只产生部分包，不冒充完整系统诊断。

## 新制品长素材真机采集

同一冻结438输入、307份iPhone制品，两轮120秒自有DASH、close连接、manifest-only准备。budget-throttle复用上轮两次降档profile（第二次60–65秒50000B/s），公开pause-resume取消第一次预约且不退款；normal复用停流profile，无公开暂停。两轮并非仅一个变量不同，不以横向差异作因果证明。两轮都要求真实生产安装；预算轮额外要求耗尽专项，最终640要求不变。

| 场景 | 预约/安装 | EOF/最终宽度 | 替换新帧间隔ms | 最大全程新帧间隔ms | 严格/重算 |
| --- | --- | --- | --- | --- | --- |
| budget-throttle | 2/1 | 120.026412/320 | 154.166 | 2071.900 | False/False |
| normal | 2/2 | 120.027522/640 | 85.625/137.191 | 323.077 | True/True |

严格1/2，独立重算1/2。原生运行退出0不替代严格结果。

### budget-throttle

最终位置120.026411572秒，原回执错误=["ValueError"]，重算错误=[{"check": "production", "error": "invalid production recovery evidence"}]。信号=[]。预算观察={"secondInstallElapsed": 53.32880733333877, "secondDownshiftElapsed": 67.15667258333997, "exhaustedSamples": 66, "qualifiedCounterfactualWindows": [{"start": 67.25897420833644, "end": 75.50897199999599, "requests": 18, "bitrate": 2797223.0950393383}, {"start": 75.50897199999599, "end": 83.50901295834046, "requests": 18, "bitrate": 2608934.194576301}], "maximumAttempts": 2, "thirdReservationObserved": false, "capabilityAccepted": false, "continuityAccepted": false, "physicalOutputVerified": false}。

连续性原始汇总={"frameSamplingVersion": 2, "sampleCount": 6661, "publishedFrames": 2881, "maximumPumpGapMs": 36.11924999859184, "maximumPublishedFrameGapMs": 2071.89958334493, "lastPublicationSampleElapsed": 123.12463654167368, "observationEndElapsed": 123.3898962916719, "trailingNoPublicationMs": 265.2597499982221, "replacementBoundaries": [{"generationBefore": 0, "generationAfter": 1, "elapsedBefore": 53.31434970833652, "elapsedAfter": 53.46851525000238, "publicationGapMs": 154.16554166586138, "positionDeltaMs": 12.037923999997702, "textureClears": 0}], "generationsWithoutPublishedFrame": [], "continuityAccepted": false, "audioSynchronizationVerified": false, "physicalOutputVerified": false}。正常重复恢复证明=null。

服务器65秒后新高档请求0个，最后高档请求startMs=60134.483083；尾段90秒后宽度=[320]。全部原生样本无应用限码率/限分辨率/固定轨道。安装后输出和错误变化={"lastInstall": 53.32880733333877, "firstHigh": 53.46851525000238, "firstLowAfterHigh": 67.15667258333997, "highAfterLow": null, "postInstallErrorCountTransitions": [{"elapsed": 53.57795195833023, "count": 0, "automaticAttempts": 2}, {"elapsed": 62.345134791670716, "count": 1, "automaticAttempts": 2}]}。

代理376条，取消2、发送失败2、未关联0、缺metrics 0、空事务0、多事务0。错误入口/域/码分布={"1/1/54": 2}。

### normal

最终位置120.027522146秒，原回执错误=[]，重算错误=[]。信号=[]。预算观察=null。

连续性原始汇总={"frameSamplingVersion": 2, "sampleCount": 6560, "publishedFrames": 2882, "maximumPumpGapMs": 33.52104166697245, "maximumPublishedFrameGapMs": 323.0769583315123, "lastPublicationSampleElapsed": 121.34387708334543, "observationEndElapsed": 121.48605562500597, "trailingNoPublicationMs": 142.17854166054167, "replacementBoundaries": [{"generationBefore": 0, "generationAfter": 1, "elapsedBefore": 37.82553737499984, "elapsedAfter": 37.91116262500873, "publicationGapMs": 85.62525000888854, "positionDeltaMs": 0.5733949999964238, "textureClears": 0}, {"generationBefore": 1, "generationAfter": 2, "elapsedBefore": 87.05867987500096, "elapsedAfter": 87.19587091666472, "publicationGapMs": 137.19104166375473, "positionDeltaMs": 17.954161999995222, "textureClears": 0}], "generationsWithoutPublishedFrame": [], "continuityAccepted": false, "audioSynchronizationVerified": false, "physicalOutputVerified": false}。正常重复恢复证明={"firstHigh": 37.91116262500873, "secondLow": 69.04393354167405, "secondInstall": 87.07829508333816, "secondHigh": 87.19587091666472, "highTailSeconds": 34.148006166680716, "stableHighTail": true, "capabilityAccepted": false}。

服务器65秒后新高档请求43个，最后高档请求startMs=110355.926042；尾段90秒后宽度=[640]。全部原生样本无应用限码率/限分辨率/固定轨道。安装后输出和错误变化={"lastInstall": 87.07829508333816, "firstHigh": 87.19587091666472, "firstLowAfterHigh": null, "highAfterLow": null, "postInstallErrorCountTransitions": [{"elapsed": 87.14949912500742, "count": 0, "automaticAttempts": 2}]}。

代理407条，取消7、发送失败3、未关联0、缺metrics 0、空事务0、多事务0。错误入口/域/码分布={"1/1/54": 5}。

## 原因结论及未完成项

本轮budget-throttle的最后高档请求为network-period-16/chunk-1-00004.m4s，服务器request229、proxy request50。v7明确记录state.failed（source1）、POSIX54/ECONNRESET先冻结终止记录，而不是monitor receive入口；代理接收并发送65536字节，服务器写到66560字节后client_io_error，素材完整长度68293字节。代理自身接纳到终止2.013931秒；服务器独立时钟下请求60.134483–62.245031秒，总2.110548秒。独立25秒截止没有作为此次首记录终止原因，也未记录为proxy.cancelAll。不能因约2秒就宣称AVPlayer存在已确认的2秒私有超时。

服务器本次高档请求等待共享速率锁0.496552秒、持锁1.596543秒，其中请求sleep1.351680秒、实际sleep1.592798秒；50000B/s是音视频所有连接共享的速率上限，无空闲或过睡信用。因此该对照不是无错误的纯带宽对照，较低有效单请求吞吐不能直接判定为生产代理缺陷。此前59.139332秒开始的高档请求完整60790字节成功；60.134483秒这一请求失败后，新高档请求为0。两段counterfactual带宽约2.797/2.609Mbps仍达门槛，最终320的严格失败保留。

新的来源字段定位的是当前可观察回调入口，不证明AVPlayer为什么发起断开或为什么不再尝试高档。服务器写完整正文也不等于播放器收到完整正文；服务器profile与设备uptime是两个时钟域，不直接相减。详细高档请求边界和后续高档请求计数见high-request-boundaries.json与error-analysis.json；未用旧版cancelCause3伪造具体入口。

预算专项与高档恢复是两个门槛；最终低档即使有两段合格带宽、预算正确耗尽仍是严格失败。当前没有已确认的、预算不变且保持用户策略的恢复行为修复，因此只修复诊断缺口，不把取证完成标为恢复完成。

新制品两平台强制上游首次连接关闭合约仍得到真实双事务，首事务无响应日期，第二次完整；该受控诱因不是历史成功双事务的内部原因。历史v2缺字节计数不能补造；旧6轮重算仍3/6，原失败保留。新媒体有无复现也不关闭历史根因。

没有校准物理屏幕/音频采集，physicalOutputVerified、audioSynchronizationVerified、continuityAccepted、capabilityAccepted仍false。发布新帧间隔与主动暂停全程间隔分列，不据单次或跨批次差异宣称性能改善。继续保留预算耗尽后的自然高档恢复、长期稳定性、更多生命周期竞争、历史双事务及macOS就绪超时、更多设备/最低系统/实际网络/授权素材与物理音画缺口；不重新加入用户删除的旧终末停顿待办。

## 历史、台账与复审

48组10118条历史哈希与基线6b468200逐项一致。只更新本轮生产诊断文件指纹及报告/下一步，102行implementation/verification/acceptance不升级；20条唯一直接引用和旧全局证据定义保留，新报告链接旧报告。结构/阈值检查及15项台账回归通过，sourceMatches=true、releaseReady=false，require-ready退出1。

独立复审另有1项P3注释措辞待完善：源码`v7 sources: 0 not an error`可更精确写为“无已记录取消错误”。实际字段和本报告已正确限定source0包含发送失败，不影响行为或验收；按集中复审流程保留为deferred minor，随下次相关源码修改一并澄清。

[独立综合复审](evidence/2026-10-29-loopback-error-source/review-final.md)与[完整证据](evidence/2026-10-29-loopback-error-source/README.md)包含红灯及两平台最终矩阵、两轮完整媒体xcresult、原始失败、请求/策略/帧日志、来源制品绑定和历史核对。未推送、合并或发布。
