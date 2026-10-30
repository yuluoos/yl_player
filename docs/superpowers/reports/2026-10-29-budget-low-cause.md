# 预算耗尽后停留低档：停流与低带宽真机对照

基线4f4a664f，承接[新制品预算与连续性验收](2026-10-29-final-media-budget.md)。用户授权准备后6–10分钟前台窗口；不得增加预算、放宽门槛或发布。沿用系统排障与集中验收。

## 对照设计与制品

438输入、307 iPhone制品与e951fce5通过原生超时修复验收的制品逐项一致；复用该制品iOS254/254、macOS229/229选定矩阵，未重建或重跑这两个矩阵。881/925为注册用例数，非本轮执行数。生产代码、策略、验收器与预算不变。

三轮iPhone16/iOS27.2均120秒、自有DASH、close连接模式、manifest-only准备。budget-stall复制旧repeat-stall-budget-diagnostic-v1，加公开pause-resume使首次预约失效不退款；budget-throttle只把第二次60–65秒的0B/s改为50000B/s，其他时点/速率/延迟完全相同，首次10–15秒停流不变；normal使用旧profile、不做公开暂停。完整参数与单变量差异见profile-delta.json，三个生成媒体清单/资产指纹相同。这是配置单变量的单次实机对照，首安装时刻等运行结果存在变异，不作随机化或统计因果结论。

两种budget场景均启用require-production-install和require-budget-exhaustion，仍要求最终640高档；正常轮要求两次安装后实际高低高序列。955000bps、双8秒窗口每窗至少3请求、缓冲5秒/剩余20秒、预算2、500/1000ms退避、准备2秒/票据5秒全部不变。控制轮即使没有再次降档，也不能算预算耗尽验收通过。

## 真机结果

| 场景 | 次数/实际安装 | EOF位置/宽度 | 替换新帧间隔ms | 最大新帧间隔ms | 预算专项 | 严格/重算 |
| --- | --- | --- | --- | --- | --- | --- |
| budget-stall | 2/1 | 120.028318/320 | 156.153 | 2082.875 | 通过 | 失败/失败 |
| budget-throttle | 2/1 | 120.028339/320 | 118.892 | 2059.888 | 通过 | 失败/失败 |
| normal | 2/2 | 120.023345/640 | 86.251/153.306 | 325.469 | 不适用/未建立 | 通过/通过 |

严格1/3，独立重算1/3；原生三轮退出0并到EOF不替代严格结果。全部原始失败保留。

### budget-stall

原回执错误=["ValueError"]；独立重算错误=[{"check": "production", "error": "invalid production recovery evidence"}]。服务器profile恢复65秒后新高档请求0个，最后高档请求在服务器profile 60080.148ms。
第2次安装56.829秒，安装后再次低档67.112秒；两合格窗口=[{"start": 68.50821179166087, "end": 76.75816695833055, "requests": 19, "bitrate": 2482317.3101178873}, {"start": 76.75816695833055, "end": 85.00816820832551, "requests": 18, "bitrate": 2510191.8912653076}]。预算最大2，无第三预约，权限/会话绑定通过。预算成功不抵消最终低档失败。
安装后输出与错误变化={"lastInstall": 56.82925270832493, "firstHigh": 57.486174791658414, "firstLowAfterHigh": 67.11205837500165, "highAfterLow": null, "postInstallErrorCountTransitions": [{"elapsed": 57.06761012499919, "count": 0, "automaticAttempts": 2}, {"elapsed": 62.23675329166872, "count": 4, "automaticAttempts": 2}, {"elapsed": 64.30830374998914, "count": 8, "automaticAttempts": 2}]}。设备elapsed和服务器profile是独立时钟，不直接相减或宣称精确跨时钟因果时刻。
代理385条，取消3、发送失败8，缺metrics 0、空事务0、双事务0、未关联0；信号=[]。

### budget-throttle

原回执错误=["ValueError"]；独立重算错误=[{"check": "production", "error": "invalid production recovery evidence"}]。服务器profile恢复65秒后新高档请求0个，最后高档请求在服务器profile 60266.216ms。
第2次安装54.330秒，安装后再次低档67.275秒；两合格窗口=[{"start": 67.51020225000684, "end": 75.51020350000181, "requests": 18, "bitrate": 2247791.5555401617}, {"start": 75.51020350000181, "end": 83.75963166666043, "requests": 18, "bitrate": 2648051.5803590766}]。预算最大2，无第三预约，权限/会话绑定通过。预算成功不抵消最终低档失败。
安装后输出与错误变化={"lastInstall": 54.33032487500168, "firstHigh": 55.28751120832749, "firstLowAfterHigh": 67.27527275000466, "highAfterLow": null, "postInstallErrorCountTransitions": [{"elapsed": 54.52750083334104, "count": 0, "automaticAttempts": 2}, {"elapsed": 62.28830404166365, "count": 1, "automaticAttempts": 2}]}。设备elapsed和服务器profile是独立时钟，不直接相减或宣称精确跨时钟因果时刻。
代理382条，取消1、发送失败5，缺metrics 0、空事务0、双事务0、未关联0；信号=[]。

### normal

原回执错误=[]；独立重算错误=[]。服务器profile恢复65秒后新高档请求44个，最后高档请求在服务器profile 110237.290ms。
正常重复恢复证明={"firstHigh": 38.37588258332107, "secondLow": 68.99530937499367, "secondInstall": 86.57724383332243, "secondHigh": 87.21729770832462, "highTailSeconds": 33.99704166667652, "stableHighTail": true, "capabilityAccepted": false}。
安装后输出与错误变化={"lastInstall": 86.57724383332243, "firstHigh": 87.21729770832462, "firstLowAfterHigh": null, "highAfterLow": null, "postInstallErrorCountTransitions": [{"elapsed": 86.70739045832306, "count": 0, "automaticAttempts": 2}]}。设备elapsed和服务器profile是独立时钟，不直接相减或宣称精确跨时钟因果时刻。
代理414条，取消5、发送失败5，缺metrics 0、空事务0、双事务0、未关联0；信号=[]。

## 可确认的原因边界

上轮失败及本轮两个budget场景的全部原生采样均无应用层限码率、限分辨率或固定轨道。后续带宽窗口已达原门槛，低档进度继续；策略返回budgetExhausted仅阻止第三次预约，没有修改AVPlayer码率参数。恢复带宽后服务器没有再收到新高档请求。故本轮低档持续不能简单归因于带宽观测不足或残留限档。

50000B/s对照也出现一次CoreMedia -12889错误，最终低档；无需将第二次故障配置为完整5秒停流也能复现该外部表现，但这个对照并未消除高档请求错误，不能据此区分纯带宽决策与请求失败惩罚，更不能证明AVPlayer私有penalty timer。两个budget场景共同保留首次10–15秒停流，不能排除首次停流或此前错误状态对后续行为的作用。

对照中最后高档chunk-1-00004.m4s，服务器profile 60266.21575–62280.129084ms写出68293字节；代理收到并发送67584字节后，回环连接失败或接收错误分支（cancelCause=3）取消，taskOutcome=1；现有trace不能区分具体回调，首响应到达而响应结束日期缺失。服务器完整写出不是客户端完整收到，两个时钟也不能直接相减。精确原始边界和v3字节计数保留于high-request-boundaries.json，不将此次单事务取消当作历史双事务缺响应的已知原因。

目前可安全确认的是预算保护按合约工作、应用未限档、请求错误后缺乏后续高档尝试这一外部表现。没有足够证据给出不增加预算且不改变用户策略的生产修复；未退款、未绕过第三次预算、未后台偷偷替换item或强制固定高档。保留该严格失败继续调查。

发布层新帧间隔按实际新帧采样，主动暂停造成的全程最大空档与替换边界分列；没有校准物理屏幕与音频采集，continuityAccepted、audioSynchronizationVerified、physicalOutputVerified、capabilityAccepted仍false，不据跨批次间隔差异宣称性能改善。

## 集中验收、历史与台账

工具200/200，消费者45通过/1既有历史focused证据缺失跳过；注册来源及881/925身份核对通过。原生矩阵为同源同制品复用，当前三轮为新增真实执行。旧6轮诊断仍3通过/3失败，历史双事务v2缺字节计数与首次响应日期仍不可恢复；新轮无复现也不关闭其内部原因。47组9987条历史证据哈希与基线逐项一致。所有运行/设备诊断警告原样保留。

继续保留预算耗尽后的自然高档恢复、跨轮稳定性、更多故障/生命周期竞争、历史双事务和macOS就绪超时，以及设备/最低系统/实际网络/授权素材及物理音画缺口。旧终末停顿待办不重新加入。

报告生成从固定基线派生20条唯一引用，不重复追加；旧全局证据定义及报告链保留。生产指纹不变，102行implementation/verification/acceptance不升级。结构/阈值和15项台账回归通过，sourceMatches=true、releaseReady=false，require-ready仍退出1。独立复审见[复审记录](evidence/2026-10-29-budget-low-cause/review-final.md)。

[完整原始证据](evidence/2026-10-29-budget-low-cause/README.md)包括三份完整xcresult、profile单变量差异、失败回执及请求/策略/帧/信号、同制品绑定与历史核对。未推送、合并或发布。
