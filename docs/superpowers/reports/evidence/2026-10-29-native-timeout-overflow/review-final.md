# 原生 HLS 超时溢出修复：独立综合复审

基线：9658ac6aa006b52e847016907e4f604f6c3206e4；审查对象：2026-10-29 当前未提交实现、三份同步原生回归、注册计数、报告与发布台账。按 requesting-code-review / consolidated-acceptance 完成本轮一次独立综合复审。审查者只读源码与既有证据，未运行设备测试、构建或修改仓库文件；本文件写入临时证据目录供归档。

## 结论

本轮修复无 Critical / Important / Minor 发现，无新增代码阻断，可在执行者完成证据归档及归档校验后形成授权范围内的本地提交。此结论仅关闭已定位的原生超时求和崩溃，不代表完整产品验收或发布就绪；不授权推送、合并或发布。

## 实现与边界

- YlHlsMediaProxy.swift:168–176、YlHlsResourceLoader.swift:267–275：在 Int64 求和前将两个操作数转为 TimeInterval，避免正、负同号极值整数溢出。Int64 极值转 Double 后及两值之和均为有限值。正常配置仍保留 1ms 资源超时下限、默认 25s 和 90s/120s 的 210s 合计。
- YlHlsResourceLoader.swift:413–418：改用 Double 秒构造截止时间，保留 1s 最小预检期限以及额外 1s。现有 Dispatch 的 Double 加法重载先对秒转纳秒结果做 Int64 饱和转换，避免重新触发整数转换 trap；极大期限受系统范围约束，不承诺精确超长计时。官方实现参考：[Swift Dispatch Time.swift](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/swift/Time.swift)。两平台实际回归也执行了极值截止计算。
- YlNetworkConfiguration.swift 的原生初始化未截断，map 初始化仍限制 60000ms。现存 YlNetworkRequestPolicyTests.testManagedBackoffRetryAfterAndClockAreDeterministic 的 90000/120000 配置，以及 media_core/test/native_module_boundary.swift 的 70000/80000 合约保持一致。
- 代理既有独立连接计时器已经先转 Double 再求和，本轮 max/max 的真实请求会经过该路径；取消后 activeConnections / connectionDeadlines 归零断言保留。

## 测试真实性与复用证据

新增 testExtremeNativeTimeoutsKeepProxyAndPreflightUsable 覆盖 max/max、min/min、0、默认、90/120 秒，使用明确数值预期，捕获配置后继续创建真实 URLSession。所有输入均创建真实代理与加载器，并完成 DASH 快照预检；只有 max/max 执行本机 HTTP 代理正文请求。报告准确区分快照预检和网络预检等待，没有把前者描述成后者，也没有将毫秒下限输入的即时网络请求作为稳定性承诺。

已查验：

- native-probe-red：同一新增测试崩溃，1 失败、退出 65；native-probe-green：1/1、退出 0。
- ios-final：iPhone 16 / iOS 27.2，254/254，0 跳过；macos-final：229/229，0 跳过。case-identities 的 expected / observed 分别相等且标明 focused selection。881/925 是注册计数，报告未冒充本轮全部执行数量。
- tools-final：200/200；消费者 46 总项、45 通过及 1 既有跳过。首次工作目录错误的 18 项导入失败仍在 tools.log / offline-results.json 中。
- source-identity 438 个冻结输入哈希均与当前文件匹配；production-source 598 个生产范围条目（包括 5 个软链）均与当前输入匹配。原生执行命令、最终摘要、结果用例树、编译/诊断输出及制品清单已存在临时证据目录。
- readiness-results 的结构/阈值/台账测试/diff 检查均为预期结果，两个 require-ready 命令仍退出 1。发布台账 sourceMatches=true、releaseReady=false；102 行 implementation / verification / acceptance 与基线逐项一致，新增报告哈希匹配。
- 报告保留 45 组、9763 项历史证据核验记录及历史 6 轮重算的 3 通过/3 失败，未改写旧失败；源码 diff 没有改动历史证据或门槛。设备诊断仅部分收集以及现存运行/编译警告也有明确说明。

执行者还需将本复审、4 个完整 xcresult 及其他临时证据归档并验证归档哈希；此项是收尾工作，不以当前临时结果替代持久证据。

## 未作结论的行为

- 极大超时的精确数值年限、超长等待后的触发时刻：本轮验证可用且不崩溃，系统时间表示和 Double 精度有有限范围，报告明确此边界。
- 本轮新制品的长素材高档恢复、预算耗尽后的自然恢复以及物理显示/音画同步：本轮未执行，旧制品结果不能绑定当前制品。
- 历史双事务根因、更多故障/生命周期竞争、最低系统/更多设备/实际网络与授权素材、历史 macOS 就绪超时：超出已定位溢出修复能够证明的范围，报告与台账继续保留未完成状态。

这些项并未静默关闭；完整发布验收仍被既有缺口阻断。
