# Dart 并发凭据竞争验证

基线8fee00f3，沿用codex/abr-recovery隔离工作树和集中验收策略，不发布。

Goal：用真实Dart/Pigeon/Apple播放器验证两个Load重叠时的凭据隔离、取消与会话归属。Architecture：专用双源HTTP夹具通过显式门闩控制旧MPD/媒体响应；赢家使用已有有效4秒视频素材，必须ready、首帧及后续进度通过；测试标记隔离每条跳转链。Tech Stack：Dart integration_test、原生AVPlayer。

- [x] 新增独立apple_dash_credential_race_test.dart，复用既有控制器创建和有效媒体，保持旧测试独立。
- [x] MPD跨源返回被挂起后启动新Load，旧future在释放旧响应前返回load.cancelled；赢家提交后释放旧响应；阻塞赢家第二分片直至旧handler结束，要求其后的新分片请求凭据正确，再验首帧与进度。
- [x] 旧Load提交但跨源媒体响应挂起后启动新Load；赢家独立凭据、旧session失效；旧handler完成后必须有新的赢家分片请求，ready/首帧/进度可用。
- [x] 逐Load/逐跳核对凭据，普通header保留，记录请求和门闩顺序；失败立即定位，只有确认产品问题才改生产。
- [x] 新增统一入口apple_dash_credential_acceptance_test.dart，一次应用启动注册前轮顺序失败与本轮2项竞争，保留各自独立入口。
- [x] 最终双平台集成、相关Dart单元、静态检查与台账统一验收，一次独立综合复审；未改原生/生产部分用源身份复用上轮原生214/189证据，若影响边界变化则重测。

保留所有原始失败；不改变ABR 2秒准备/5秒票据/双8秒窗/955000bit/s/2次预算/500和1000ms退避。短素材首帧/进度不等同长素材升档、物理音画连续性或所有并发交错已穷尽。缺设备/授权资源继续保留。

完成记录：[统一验收报告](../reports/2026-10-28-dart-credential-race.md)。真实集成双平台各3项通过，Dart单元29项通过；未改生产实现。
