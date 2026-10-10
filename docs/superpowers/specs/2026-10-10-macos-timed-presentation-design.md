# macOS 激活期间持续供帧：原生定时显示候选设计

状态：用户于2026-10-10确认“按推荐设计继续”；待实施，不是已实现或已准入功能。基线 `3f41cb0`。

## 目的与范围

解决已复现的首次前台激活期间主线程阻塞导致视频供帧中断的问题。目标是在主线程发生约150–300ms的激活工作时，已经播放中的本地有限媒体仍由独立供帧队列持续向系统提交按PTS显示的样本。不能以忽略丢帧、增加主线程积压、暂停媒体时钟或提前激活窗口代替修复。

沿用用户约束：不用商业SDK；macOS最低版本仍为12；先完成本机可执行验证；后续iOS测试优先iPhone18 Pro Max；音频候选的默认开关、生产准入和整体下游资源上界保持false。

首个候选限定为macOS 14及以上、`YlManagedPlaybackSession`、已附着的原生视频视图、本地有限文件、普通非bounded缓冲模式。macOS 12/13、iOS、纯Flutter纹理、AVPlayer后端、直播和bounded缓冲继续使用现有路径。这些路径不列为此次抗阻塞修复已覆盖的范围。候选先通过内部测试注入启用，不增加用户设置、不默认开放；启用范围扩展须有对应的生命周期与时钟验证。

## 已有证据与验收缺口

- [根因报告](../reports/2026-10-10-display-activation-root-cause.md)记录了Debug宿主外部激活后无Instruments仍出现4帧丢弃的结果。
- `YlDisplayTimer`在main/common触发；`YlPresentationCoordinator`在回调中按音频时钟选帧。百毫秒空档出现在回调进入前。
- `YlVideoSurfaceMailbox`只保留最新一帧并切回main；`YlSampleBufferVideoRenderer`使用PTS=0与DisplayImmediately。直接后台调用现有publish不能跨越这处主线程依赖。
- `YlAppleTextureOwner`与lease还管理候选后端切换。不能绕过lease直接把解码帧交给真实输出，否则旧会话可以覆盖当前画面。
- `testActualDecodedTerminalContinuousObservation`使用`DecodedTexture`计数输出，不附着实际原生层。它是调度证据，不是画面持续显示的证据。
- Debug与Profile构建的激活结果必须分开。Profile对照只用于确定影响范围；一次未复现不消除已证实的结构性依赖。
- 本轮Profile/AOT对照已复现：活动丢弃12帧（请求前1、请求后11），最大回调间隔455.030ms、最大视频落后224.750ms。后台utility探针也有206.806ms空档，不能把全部空档都归为main独占，不能保证50ms提前窗口抵御进程整体调度停顿；候选必须测自己的worker延迟。[记录](../reports/2026-10-10-display-profile-activation.md)。

## 方案比较

| 方案 | 收益 | 局限 / 决定 |
| --- | --- | --- |
| 提前初始化输入系统，或调整应用激活时机 | 可能减少某次首次激活开销 | 不能控制AppKit其他主线程工作，改变宿主行为；不采用为播放器修复 |
| 只将现有显示定时器迁到后台 | 可继续选帧 | mailbox仍回main，且会引入会话状态与lease竞态；不采用 |
| 独立供帧队列＋系统按PTS显示 | 解码供给和样本投递不依赖main逐帧运行 | 需要显式时钟、lease与清理契约；推荐作为受控候选 |

Apple公开文档说明[`sampleBufferRenderer`](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/samplebufferrenderer)支持后台安全enqueue；本机SDK标注macOS14起可用。不能在同一层混用displayLayer与sampleBufferRenderer的入队接口。保持现有层布局、附着和移除操作在main。

## 数据与线程边界

1. **解码与有界队列**：仍由现有解码链产生`YlFrameEnvelope`，保留PTS、duration、generation和reservation。扩展调度器的有序取帧能力：取下一帧，而非以“当前时刻”为名把提前投递标为已显示。旧`frame(at:)`行为不变。新队列使用独立的lastSubmittedPTS；不能改名复用lastPresentedPTS来制造通过。
2. **供帧worker**：每个候选播放会话最多一个串行队列和一个有界唤醒源。解码帧到达、renderer就绪与短周期时钟同步可触发工作；合并唤醒，不为每帧无限追加closure。worker不调用AppKit、Flutter事件通道或现有`presentationDidTick`整段逻辑。
3. **主线程会话逻辑**：状态事件、firstFrame、缓冲状态和完成判定仍在main。worker只能发出带会话身份和epoch的合并通知；回到main后二次校验身份。短暂延迟状态事件不能停止正在运行的供帧worker。
4. **显示endpoint**：main创建并附着displayLayer，设置controlTimebase，再将其sampleBufferRenderer交给worker。只通过sampleBufferRenderer执行ready/enqueue/flush；布局与移除仍由main负责。未附着时不累计定时样本。
5. **租约**：新增可选定时输出能力，由owner发放仅当前已commit lease可使用的endpoint。候选lease在commit前只能准备，不能enqueue。切换时先关闭旧endpoint的提交权限，再清空旧系统队列，最后开放新epoch。旧回调、旧错误、旧firstFrame均不能传递给新会话。

## 时间、容量与背压

媒体时间仍由`YlMediaClock`提供，不建立第二个独立走时的播放器时钟。worker取得一致的播放状态、rate、generation和媒体/host时间快照；controlTimebase由该快照锚定，系统依据样本真实PTS显示。定时样本不设置DisplayImmediately。首帧预览与定时播放必须明确切换并flush，不将预览样本混入定时队列。

候选参数固定为：最多提前50ms墙钟时间，最多3个尚未到期的视频样本。两项同时限制；不足时不为凑足3帧而越过时间上限，4倍速以rate换算媒体PTS窗口。供帧唤醒周期上限10ms；这是测试候选值，不能作为无限抗阻塞承诺。主线程阻塞300ms期间由worker连续补充，不依靠预排300ms画面掩盖依赖。

保留原解码队列及其容量，最多额外保留3个未到期样本引用；系统持有样本与应用引用共享同一reservation，不重复扣费。reservation仍跟随CMSampleBuffer真实释放，不在PTS到期时虚构系统释放。相同PTS重复提交、未就绪重试、延迟时钟快照都不能无限增长系统队列。ready=false时停止提交，用一次配对的request/stop等待，并受epoch取消。

现有字节预算继续生效；不得通过扩大maxBytes、提前释放reservation或绕过解码资源限制让候选通过。这里的3帧限制只约束应用未到期提交窗口，不能证明系统内部资源总上界，A5仍开放。

已有音频已呈现位置优先；无音频时沿用host回退。初始音频锚定在main完成后才允许进入候选运行态；音频采样读取必须确认线程安全，worker不持有session锁跨越系统调用。暂停、rate变更和seek通过同一worker控制序列同步timebase与队列。不能简单把host时钟按rate推进后长期不校准音频；实际允许误差以现有100ms门限为上限，并记录每次同步差值。

## 生命周期契约

| 操作 | 必须实现的结果 |
| --- | --- |
| play | 当前epoch、已附着且时钟已锚定后启动供帧；不等待main逐帧tick |
| pause | 控制命令生效后timebase速率为0，worker不再提交；保留有界未来帧用于resume，不提前显示它们 |
| resume | 从暂停媒体位置恢复，重新同步timebase；恢复后不重复上报firstFrame |
| rate | 用同一个媒体位置切换rate及提前窗口，禁止未来样本跳到错误host时间 |
| seek / load / 后端切换 | 立即关闭旧epoch提交；flush完毕前不接收新epoch；旧队列与旧错误无权影响新画面 |
| EOF | 以解码、音频及视频定时队列的排空联合判断；enqueue成功不能被当作视频已结束 |
| detach / suspend | 关闭endpoint并取消worker供给；释放排队样本，不积累离屏future队列；重新附着从当前媒体位置重建 |
| close | 先撤销权限，再停止worker及request回调，再清理renderer/主线程layer；延迟回调无操作，重复close幂等 |

关闭不能持有session锁等待worker；worker也不能同步等待main。flush完成回调携带epoch，旧flush不能清空新epoch。实际retire采用独立旧endpoint持有清理资源直到完成，且在完成前不开放替代endpoint；不允许快速seek创建无界退役列表。

## 失败与回退

能力检查不满足时，在播放开始前选择旧路径。运行中的renderer失败不能悄悄切到旧路径后丢掉错误证据：按现有`render.video_surface_failed`报告原生domain/code与失败阶段，经身份校验后交给当前会话。测试注入开启但候选未使用时，验收必须失败，不能用fallback结果冒充候选结果。

## 验证顺序与完成标准

1. **最小失败验证**：真实附着的原生层、实际解码媒体，在稳定播放后确定性占用main 250ms；旧路径留下供帧空档/丢帧证据。保留现有真实NSWorkspace激活复现，避免只验证人为sleep。
2. **行为验证**：帧有序、无越代、50ms/3帧窗口、暂停不推进、resume连续、rate切换、seek与flush竞态、EOF不早报、detach/reattach、连续close。对worker取消采用可控屏障，不依赖偶然线程时序。
3. **真实输出验证**：检查系统视频性能指标及其可用性，分别保存submitted、系统total/dropped/corrupted/frameDelay和应用丢帧。系统指标缺失不能按0处理。macOS14.4起可用的`copyDisplayedPixelBuffer`仅在rate=0时有效，不能拿它当播放中逐帧采集API。需要暂停末帧验证时使用可辨识画面与预期PTS，且记录测量扰动。
4. **集成对照**：Debug及Profile各自保留旧路径/候选的实际激活30s结果；固定媒体、激活时刻、诊断配置，逐组串行运行。候选必须确实穿过owner→lease→原生endpoint；计数输出单独通过不够。
5. **最终回归**：针对受影响的共享lease/时钟/生命周期运行macOS相关套件；共享行为有改变时在iPhone18 Pro Max跑对应回归；确认后再运行一次候选长播，冻结源码/二进制身份。无关全套与长播不在每个小提交重复运行。

本机完成标准：候选在确定性main阻塞与实际激活下保持有序供帧；原生指标支持显示连续且无新增丢帧；生命周期、字节预算和关闭后资源检查通过。只有enqueue计数连续时，最多称“供帧独立于main”，不得宣称“画面卡顿修复”。系统指标仍不是物理屏幕/扬声器测量，不消除R4设备验收缺口。

## 审阅后的实现分组

先完成可选endpoint与lease权限、时钟快照/有序取帧及失败测试；再接入macOS renderer worker与生命周期；最后完成真实层、激活对照和集中回归。此处为依赖顺序，不是已审批的实施计划或已完成状态。
