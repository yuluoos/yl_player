# iOS 提交后媒体失败的凭据生命周期

基线90be00d1；继续既有授权与集中验收策略，不发布。复用当前隔离工作树。Goal：补齐成功Load回复之后真实媒体失败、恢复、再次Load的凭据边界。Architecture：真实typed native host、AVPlayer与受控双源HTTP；源码无已确认缺陷时不修改生产逻辑。Tech Stack：Swift/XCTest/AVFoundation。Spec：上一轮ios-load-lifecycle报告剩余边界。

- [x] 在canonical YlDashResourceLoaderTests新增真实HTTP410造成item失败的测试，双平台镜像同步。
- [x] 验证原会话失败事件身份、恢复沿用剥离上下文、新Load使用独立上下文及旧session失效；若有失败先定位再修复。
- [x] 新增真实Dart→Pigeon→原生集成测试，验证两个已提交会话的失败事件、ready/firstFrame失败、跨源凭据剥离及旧session命令拒绝；只用回环合成凭据。
- [x] 最终受影响原生双平台、消费者镜像/来源与台账集中检查，一次独立复审，完整保留失败。

不改变2秒准备/5秒票据/双8秒窗/955000bit/s/2次预算/500与1000ms退避。此失败观察5秒为新合约等待上限，不改变ABR门槛。不冒充Dart桥接、长素材高档或音画连续性；不要求失败后自动回滚旧会话，公开Load已完成提交。

本轮完成：[统一验收报告](../reports/2026-10-28-ios-postcommit-failure.md)。原生iPhone214/macOS189；真实Dart合约双平台各1通过。整体ABR/物理连续性与外部资源项仍保留。
