# 高档帧触发再次降档、预算耗尽与连接诊断

基线c7342f8c，承接[上轮重试与带宽对照](2026-10-29-reset-retry-control.md)。用户授权当前条件下继续实施、三轮前台采集；首轮音频中断后再次确认继续剩余两轮。沿用系统排障、测试驱动和集中验收，不增加预算、不退款、不放宽门槛、不发布。

## 已实施与边界

修复的是测试场景的固定时间假设：新采集器在真实生产安装后，等待同代际至少48个高档发布帧、跨度至少2秒且持续推进，再一次性请求5秒故障；位置不得超过70秒，暂停、等待定位、低档、代际变化、非推进或超过0.5秒发布间隙会打断基线。独立控制端仅绑定自有地址和随机运行token，不占媒体处理线程；校验有界正文、连接截止、重复触发及回执。无回执不重发，所有失败保留。客户端证据、宿主触发/结束时刻与原始帧/安装事件逐一绑定。

`triggered_fault.py`及5项测试覆盖在途限速、边界恢复、身份/重复、错误/过晚输入、伪造/缺失回执和中间暂停。保留功能缺失红测试、暂停反例红绿以及最初沙箱socket权限失败。纯Swift状态机先以nil桩运行失败断言，再运行实现通过；初次脚本private访问级别编译错误与修正后的红绿分开保留。增加一项两平台原生测试，原生探针只发诊断控制请求，不安装候选、不改变生产控制器或预算。共享fixture和两平台副本精确同步，注册884/928只代表来源数量。

基准静态profile是0秒500000B/s+40ms、10秒停流、15秒2000000B/s+0ms，此后不再预排第二故障。新故障是独立事件覆盖层，三轮均0B/s持续5秒；原profile指纹和请求phase字段仍表示基准阶段，不能把它们当作覆盖期间实际速率。故障实际区间见fault-server.json，设备确认区间见fault-trigger.json，各用自己的单调时钟，禁止直接相减。这是新触发式对照，不冒充原固定时间配置。

额外保留server-health.json中至多1000条服务循环存活、已接纳/活动/拒绝计数；它能说明循环是否仍在运行，不能证明网络包到达或回填历史失效。生产Swift文件和生产发布指纹与基线完全相同；预算2、955000bps、双8秒/每窗3请求、缓冲5秒/剩余20秒、500/1000ms退避、2秒准备/5秒票据全部不变，严格媒体/预算/连续性验证函数未改。

## 集中测试与三轮真机

新iPhone16/iOS27.2选定矩阵257/257，macOS232/232，无失败或跳过，实际用例身份与所选集合完全匹配；工具211/211，消费者45通过/1既有focused历史证据缺失跳过，来源检查通过。442份捕获输入、307份真机制品冻结并绑定三轮回执；采集后更新README，并按独立复审修正宿主未启动清理及追加第二低档校验（abr_accesslog.py、triggered_fault.py及测试）；捕获时442份输入指纹与4份不同版本的完整来源单独保留，完整来源经捕获时哈希精确验证。最终宿主工具211项回归及三轮证据重新复算；307份原生制品、所有Swift和生产输入没有变化，复用原生结果，未把捕获前宿主版本冒充最终版本。原生编译警告原样保存。

| 场景 | 预约/安装 | 末次位置/宽度/完成 | 故障设备触发秒 | 再次低档秒 | 替换新帧间隔ms | 严格/复算 |
| --- | --- | --- | --- | --- | --- | --- |
| budget-zero | 2/1 | 98.957058/320/False | 57.441718 | 67.44394958333578 | 292.791 | False/False |
| normal-zero | 2/2 | 120.018289/640/True | 36.664300 | 45.19892350000737 | 229.799 / 208.442 | False/False |
| budget-zero-repeat | 2/1 | 120.029522/320/True | 65.295416 | 75.2991458333272 | 153.719 | False/False |

整轮严格0/3，独立复算0/3。触发证据三轮均真实绑定；有效再次降档不等于已经恢复高档或能力验收。

### budget-zero

原生退出65；原回执错误=["ValueError"]，独立重算错误=[{"check": "production", "error": "invalid production recovery evidence"}, {"check": "playback", "error": "incomplete or invalid ABR observation"}, {"check": "budget", "error": "invalid repeated downshift budget evidence"}, {"check": "signals", "error": "interruption"}, {"check": "native", "error": "65"}]。帧宽度阶段=[{"elapsed": 0.5635262499999953, "width": 320, "generation": 0}, {"elapsed": 4.910810291665257, "width": 640, "generation": 0}, {"elapsed": 16.91141295833222, "width": 320, "generation": 0}, {"elapsed": 55.43140295833291, "width": 640, "generation": 1}, {"elapsed": 67.44394958333578, "width": 320, "generation": 1}]。

代理359条，取消6、未关联0、多事务0、缺metrics 0、成功但事务不完整0。服务循环最大采样间隔0.540632秒，末次快照={"listenerSeconds": 153.4551295000001, "profileSeconds": 141.99916441599999, "accepted": 361, "active": 0, "rejected": 0}。全部原生导出均未记录failed to connect或HTTP load failed，本轮没有重现上游连接超时；不能由此关闭历史失败。

最大发布间隔2088.815ms，末次发布后无帧至观测结束37875.442ms；无帧代际=[]。中断记录=[{"applicationState": 0, "elapsed": 102.38286716667062, "interruption": 1, "options": -1, "reason": -1, "signal": "audioInterruption"}, {"applicationState": 0, "elapsed": 107.1568580000021, "interruption": -1, "options": -1, "reason": 3, "signal": "audioRoute"}, {"applicationState": 0, "elapsed": 115.82295533333672, "interruption": -1, "options": -1, "reason": 3, "signal": "audioRoute"}, {"applicationState": 0, "elapsed": 115.82851995833335, "interruption": 0, "options": 1, "reason": -1, "signal": "audioInterruption"}]。

### normal-zero

原生退出0；原回执错误=["proxy request correlation incomplete"]，独立重算错误=[{"check": "proxy", "error": "proxy request correlation incomplete"}]。帧宽度阶段=[{"elapsed": 0.48347054167243186, "width": 320, "generation": 0}, {"elapsed": 8.844744750007521, "width": 640, "generation": 0}, {"elapsed": 16.833467708333046, "width": 320, "generation": 0}, {"elapsed": 34.656267916667275, "width": 640, "generation": 1}, {"elapsed": 45.19892350000737, "width": 320, "generation": 1}, {"elapsed": 65.61032154166605, "width": 640, "generation": 2}]。

两次安装高低高及高档尾段={"firstHigh": 34.656267916667275, "secondLow": 45.19892350000737, "secondInstall": 63.58102433333988, "secondHigh": 65.61032154166605, "highTailSeconds": 55.96514020834002, "stableHighTail": true, "capabilityAccepted": false}。

代理416条，取消4、未关联2、多事务0、缺metrics 0、成功但事务不完整0。服务循环最大采样间隔0.502919秒，末次快照={"listenerSeconds": 128.49328945900015, "profileSeconds": 123.10259408299999, "accepted": 416, "active": 0, "rejected": 0}。全部原生导出均未记录failed to connect或HTTP load failed，本轮没有重现上游连接超时；不能由此关闭历史失败。

最大发布间隔388.731ms，末次发布后无帧至观测结束106.315ms；无帧代际=[]。中断记录=[]。

### budget-zero-repeat

原生退出0；原回执错误=["ValueError"]，独立重算错误=[{"check": "production", "error": "invalid production recovery evidence"}]。帧宽度阶段=[{"elapsed": 0.5606868749891873, "width": 320, "generation": 0}, {"elapsed": 4.8559592083329335, "width": 640, "generation": 0}, {"elapsed": 16.862394583324203, "width": 320, "generation": 0}, {"elapsed": 63.284661083322135, "width": 640, "generation": 1}, {"elapsed": 75.2991458333272, "width": 320, "generation": 1}]。

完整预算专项观察（secondInstallElapsed为第2次预约的安装时刻，非第2个成功安装）={"secondInstallElapsed": 61.37421866666409, "secondDownshiftElapsed": 75.2991458333272, "exhaustedSamples": 65, "qualifiedCounterfactualWindows": [{"start": 83.80292149999877, "end": 91.80294262499956, "requests": 18, "bitrate": 1679580.06202848}, {"start": 91.80294262499956, "end": 100.052237625001, "requests": 18, "bitrate": 1975173.1212675292}], "maximumAttempts": 2, "thirdReservationObserved": false, "capabilityAccepted": false, "continuityAccepted": false, "physicalOutputVerified": false}。这证明本轮预算耗尽后的合格观察窗口且无第三次预约，未证明恢复高档。

代理386条，取消5、未关联0、多事务0、缺metrics 0、成功但事务不完整0。服务循环最大采样间隔0.503093秒，末次快照={"listenerSeconds": 128.88369570899977, "profileSeconds": 124.73402387499982, "accepted": 388, "active": 0, "rejected": 0}。全部原生导出均未记录failed to connect或HTTP load failed，本轮没有重现上游连接超时；不能由此关闭历史失败。

最大发布间隔2096.894ms，末次发布后无帧至观测结束183.213ms；无帧代际=[]。中断记录=[]。

首轮budget-zero在第2次预约的唯一成功安装后发布高档，于设备57.441718秒触发、67.443950秒降档。102.382867秒发生系统audioInterruption，之后有audioRoute变化，未完成，原生65。最后位置98.957058秒，后续37.875442秒无新发布帧。中断前截取到102.363645秒的诊断前缀可形成67.511411–75.760702及75.760702–83.761411秒两窗口（约1.661/1.759Mbps）；该前缀只作因果排查，整轮仍因系统中断、hostFailure及未完成失败，禁止替换整轮回执。

normal-zero第1次安装后高档基线触发故障，发生再次低档，并由剩余第2次预算安装恢复高档，最终640到EOF，无信号/hostFailure。严格失败来自两个旧proxy请求129/130没有服务器关联：cancelCause=1，对应生产cancelAll入口，taskOutcome=cancelled、source/domain/code均0；一个任务约12.8ms，一个约0.8ms，均没有连接/请求阶段日期，Foundation请求/响应字节计数全部0。原始trace保留，不能据0计数断言没有发包，也不能将这些取消静默丢掉以通过全关联门槛。它们与POSIX54错误路径不同，不将本次cancelAll归因回填给其他历史取消。

budget-zero-repeat没有系统中断、无hostFailure、完整到EOF。第2次预约的唯一成功安装在61.374219秒，首高档63.284661秒，65.295416秒触发，75.299146秒再次低档。83.802921–91.802943及91.802943–100.052238秒窗口分别18请求、约1.680/1.975Mbps，预算仍2且无第三次预约。完整预算专项成立；最后仍320，原生产恢复验证器拒绝。该轮将“对照未成立”推进到“对照成立但预算耗尽后未自然恢复高档”，未用增加预算规避失败。

## 故障期间的高档请求与后续尝试

按实际MPD中width=640的Representation ID及完整Period路径解析高档资产后，用既有严格v7关联工具复算：两轮预算场景的新proxy请求43/44分别记录cancelCause=3、source=1、POSIX54，录得终止之后同proxy没有新的高档接纳，其他proxy也没有后续高档。首轮观察受102秒音频中断截断，复测则完整观察到EOF；这只证明本次窗口内没有新尝试，不解释AVPlayer私有penalty时长。

这两个高档请求在服务器故障开始之前约15/14毫秒已经进入，传输跨越5秒覆盖区间。服务器分别记录完整写出，但代理只记录19456/16384字节后取消；服务端写完不证明播放器接收或显示。retry-analysis.secondPhaseHighFailures只含故障开始后的新接纳，其空列表不表示故障期间无失败；必须同时查看fault-overlap中的在途请求。不能用“请求开始必须晚于故障”过滤掉这些在途失败，也不能把回环POSIX54与上轮上游连接建立1:60混为同一种错误。normal-zero的全关联不足，因此严格重试诊断拒绝给出“没有重试”的结论。

最初临时分析错误地把未展开的MPD模板当完整资产路径，空reset列表不成立；该输出以retry-analysis-invalid-asset-resolution.json及明确纠正说明保留，不用于任何结论。最终retry-analysis.py从实际高档ID与已关联资产构造集合并验证非空，fault-overlap.py只在同一服务器时钟内判断故障区间重叠；根因与能力标记均false。

## 综合复审修复

独立复审发现两项宿主工具缺陷：带有后续静态故障的非法profile在监听器创建后才拒绝，finally调用未启动服务循环的shutdown会阻塞；初始触发验证只核对高档基线，没有强制出现第二次低档。先保存反例红测试，再将profile校验前移并只对已启动线程shutdown，同时在新opt-in验证器要求触发后同代际320发布且位置推进。5项定向测试全过；真实CLI非法profile在约0.523秒返回1并写失败回执，没有生成xctestrun或启动原生采集。旧严格验证函数未改，不减少门槛。

复审两项问题已关闭。原始捕获回执及全部失败保留，新宿主验证器对三轮均确认触发后第二次低档，但不改变整轮0/3结论。详情见review-fixes-red/green.log、rejected-profile-command.json及capture-source-files。

## 双事务和连接超时调查

再次读取上轮normal完整xcresult的原生标准输出，在替换附近发现C284的TCP flags=[R]和Receive failed with error Connection reset by peer。日志没有足够连接到correlationID/事务的绑定，不能仅凭相邻时间声称它就是缺响应的首事务。

本轮新增独立macOS回环短诊断：正常连接1事务/解析1次；立即在解析前RST，接受2连接但只解析第2次，首事务请求头计数0；接受后等待20ms、仍不读取HTTP即RST，接受2连接/只解析第2次，首事务请求头计数238、响应计数0且响应日期缺失，第二事务完整，最终200/4字节；解析请求后RST则解析2次。最终诊断等待URLSession失效回调后读取指标，全部4组sessionInvalidated=true，初次未显式等待会话失效的版本独立保存，未作为最终证明。

这一控制证明：正请求头计数加单次应用解析，可以由解析前重置产生；不是“字节计数必须意味着服务器解析过”或“服务端只解析一次就不可能有内部重试”。它是macOS主动诱导的可行机制，不能归因历史iOS：历史服务器还只有1条已接纳连接，而本控制接受了2条；不能替代内核/网络证据，也不回填旧v2缺失计数为0。上轮自然v3与历史v2原始失败保持不变。

当前账号不能读写本地BPF设备，已记录packet-capture-access.json；未提升系统权限或假装具备抓包结果。新三轮服务器循环和已接纳日志完整、没有再次连接超时，但尚不能判定历史Wi-Fi/主机/服务器接纳路径内部失效点。继续保留上游超时、历史双事务、快取消全关联、最低系统/其他设备/真实网络/授权素材与物理屏幕音频校准缺口。发布帧数据不等于物理音画连续，所有continuityAccepted、audioSynchronizationVerified、physicalOutputVerified、capabilityAccepted保持false；不重建用户已删除的旧终末停顿待办。

## 台账与归档

50组10531条历史内容哈希与基线c7342f8c一致。102行implementation/verification/acceptance不升级，保留20条唯一直接引用与全部历史全局定义，只替换CAP-ABR/iOS本轮报告引用及下一步。生产指纹不变，sourceMatches=true、releaseReady=false，require-ready退出1；结构/阈值检查和15项台账回归完成。

[独立综合复审](evidence/2026-10-29-triggered-downshift/review-final.md)与[完整证据](evidence/2026-10-29-triggered-downshift/README.md)包含红绿、警告、三个原始失败、完整5份xcresult、两种时钟触发回执、历史诊断、只读哈希核对和缺口。不推送、合并或发布。
