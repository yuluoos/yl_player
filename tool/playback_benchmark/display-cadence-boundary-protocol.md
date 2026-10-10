# 显示调度边界诊断（2026-10-10）

承接 2235024：无探针 long 在约55s已有9次活动丢帧；此前探针入口位于 refreshCadence 之后，不能排除屏幕查询耗时。本次不重复正式长播，不改变零丢帧/100ms门限。

使用既有 CadenceFactory 包装实际 YlSystemDisplayCadence 回调，新增入口时间；原 tick 入口测量刷新查询结束，回调退出测量调度工作结束。仅把原生 cadence 类从 private 改成 internal，供 @testable 工厂复用；不复制系统实现、不改变生产节拍。探针默认关闭，累计计数/最大值与32条慢事件有界；独立50ms主队列探针保留最近16次完成时间，慢事件附带相关响应。该响应只证明离散时点的可用性，不证明整个间隔无阻塞，也不区分 WindowServer、系统显示链或线程调度原因。

先验证确定性分界、容量、停机隔离和关闭转发。随后一次诊断：long原生模式，首个活动drop再取一行或120s结束，父期限240s；只向本次 owned xcodebuild 发SIGINT，保留预期中断结果和原始前缀。无heap/MSL/线程采样，不并行原生测试或构建。启动前冻结源码与二进制，结束核对。诊断不得计作 short/long 门禁通过；无复现不能证明修复。旧四项 timingDiagnostics 保持兼容，新增 cadenceBoundary 独立校验。
