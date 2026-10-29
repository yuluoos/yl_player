# 半关闭修复同次最终证据复审

基线 28ddf707。独立复审者仅读取源码、原始附件、执行身份、媒体记录、报告与台账，并作离线哈希/字段核查；未与主任务竞争设备。生产 SHA-256：24d90e6814c58851f4185582a1606c597e029372fc095ce259ed7d5f6e523993。

## 结论与范围

无新增阻断发现。本轮可以验收“完整 HTTP 请求的写端半关闭仍交付响应，以及接入至发送收尾的有界回收”这一修复，证据包括两平台原生探针、选定矩阵和新真机两种 profile。它不是整体媒体能力/发布批准，也不关闭历史双事务或 AVPlayer 主动关闭的根因问题。

## 核查结果

- 生产锁、admission fence、timer 弱引用与所有终结路径的审查见 review-code.md。最终生产指纹与静态审查版本一致。438 个输入文件、307 个 iPhone 制品逐项重新计算 SHA-256 均匹配；两轮 receipt 的 binaryHashes 均等于冻结清单。
- 最终 iPhone 253/253、macOS 228/228，通过的 case-identities 中 expected/observed 数量对应、无跳过，是 focused selection。没有误称全部注册的 880/924 用例均执行。初轮 iPhone 252/253、macOS 227/228 的退出 65 与唯一 unwaited expectation 失败仍保留，测试 fixture 修正与最终成功分开。
- 读取最终两平台原始半关闭附件：直连和代理均收到完整正文且无接收错误；代理 outcome=0、taskOutcome=0、cancelCause=0。红测在基线失败、绿测在修复后通过。排队半关闭测试位于最终成功矩阵。
- 读取最终 deadline 附件与 probes.py 的硬断言：四模式连接/task/timer/trace 均归零；mode 2 没有错误准入；静默和完整断开约 0.5 秒关闭。nonreader 在 iOS/macOS 都是 cause4/outcome1、4 次 send/3 次完成；iOS bodyBytes=2113466 > sentBodyBytes=1168527，macOS 2199003 > 1103147，关闭分别 0.500298/0.499523 秒。这排除了响应全部被缓存后正常结束的伪覆盖。该结论来自受控配置和未完成发送共同证据，不把任意历史 cause4 解释为 deadline。
- 新 normal 的 receipt 严格通过，独立分析无错误：409 条代理记录、6 取消、0 缺 metrics/空事务/双事务/未关联；两次实际 installed，帧记录先高、再低、再新 generation 高，第二次高档稳定尾部 34.408645 秒，结束位置 120.027872、宽度 640。
- 新 original 的 receipt 严格通过，独立分析无错误：340 条代理记录、4 取消、0 缺 metrics/空事务/双事务/未关联；无自动安装事件，自然完成于位置 120.023510、宽度 640。报告正确地未将其当作第二次安装证据。两轮合计严格 2/2、重算 2/2；连续性/物理输出/整体能力标记仍 false。original 最大新帧间隔 1388.702ms 明示，未包装为物理音画同步通过。
- 报告准确保留阈值、预算、退避、窗口、成功事务时间完整性与服务器关联门槛。生产 diff 不触及这些阈值/验收工具。旧六轮离线 replay 仍 3/6，历史 legacy 字节不可用与缺响应日期未被补造。
- 台账与基线逐行比较，102 行 implementation/verification/acceptance 均未改变；仅当前生产代理指纹、报告引用及下一步文本更新，旧全局证据留存。新报告 SHA-256 与 inventory 绑定匹配。readiness 输出 sourceMatches=true、releaseReady=false；结构/阈值检查为 0，两个 --require-ready 仍为 1；15 项台账测试通过，diff 检查通过。

## 必须保留的边界

基线 native 直接构造极端 Int64 超时时，URLSession 初始化的旧 connectTimeoutMs + readTimeoutMs 加法仍有溢出风险；map 路径各项夹到 60000ms，新 timer 计算分别先转 TimeInterval，不引入新的整数加法溢出。这是独立既有边界问题，报告已保留，不混入本修复通过范围。

历史双事务首事务无响应日期、真实关闭决策、更多设备/最低系统/网络与授权素材、物理显示及音画同步等缺口继续开放。不能用本轮两个成功样本倒推历史根因或宣称跨批次性能提升。不批准合并、推送或发布。

归档复核：历史 44 组 SHA256SUMS 与 28ddf707 逐字一致，9595 条文件哈希逐项匹配。新归档首版 166 个条目/154 条 provenance 已校验；8 个 xcresult 压缩包逐个展开读取，内部文件哈希集合与 bundleFiles 完全一致，其他归档文件解压后与原始内容逐字相同。首版打包早于本文生成，未含 review-final.md；主任务需刷新归档纳入此文并复核新增清单，既有 8 包的内容校验已完成。
