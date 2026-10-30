# 预算低档原因：独立综合复审

基线：4f4a664f78f633dfffe83c191311242eb506f2b5。复审对象为本轮计划、报告、inventory 改动及 `/private/tmp/yl-budget-low-cause` 原始证据与分析/归档脚本。按 consolidated-acceptance 与 requesting-code-review 执行本轮一次独立综合复审；只读检查，无设备操作、源码修改或额外全量矩阵执行。

## 已核查

- 对照配置只有第 3 步 bytesPerSecond 从 0 改为 50000；两个 budget 命令除输出目录及 profile 名称外相同。共同首次 10–15 秒停流、第二次 60–65 秒扰动、公开 pause-resume、预算 2 和严格最终高档要求均保留。三份 fixture 清单及全部清单资产逐项哈希一致。单次实机具有运行变异，不能视为随机化统计因果结论。
- 438 个源码/构建输入与 307 个 iPhone 制品逐项哈希匹配冻结证据；生产、验收工具、原生测试源码无本轮改动。复用原生摘要 iOS 254/254、macOS 229/229，未伪称本轮执行。三份新增 xcresult 摘要各为 1 passed / 0 failed。
- 独立从 rows / frame-samples 调用未变严格验收函数，结果为 budget-stall 失败、budget-throttle 失败、normal 通过；两预算专项重算与回执相同。三轮原生 exit 0、EOF >=120 秒、无 signals、ownedProcessExited=true；原生成功不替代严格失败。最终宽度 320/320/640，两个预算耗尽场景没有被洗白。
- 全部采样包含且实际满足 acceptedMaximumBitrate / acceptedMaximumWidth / acceptedMaximumHeight / fixedTrackId=null、peak / maximumWidth / maximumHeight=0。未增加预算、退款、强制高档或改门槛。两次安装后高低高及 normal 尾部高档证据与分析相符。
- 385/382/414 个代理请求分别唯一关联到服务器 trace；全部有 v3 单事务 metrics。按服务器时钟独立计算恢复 65 秒后高档请求为 0/0/44。服务器和设备时钟未直接相减。68293 字节 server write 与 67584 字节 proxy receive/send 为不同边界，报告未把 server complete 当作客户端完整接收。
- 适配脚本覆盖两个 budget 名称并对两者都执行 budget 与 command 检查；normal 保留两次实际安装和 fresh high-low-high 检查。资产 rendition 从 MPD 解析；边界脚本使用固定 fixture 的 id=1，已与本轮 MPD 640 宽度对应关系核对。
- 工具日志 200 passed；消费者 45 passed / 1 既有 skipped；注册核对 881/925。47 组、9987 条历史归档 hash 与基线逐项一致。102 行 implementation / verification / acceptance、生产 source、旧 evidence 定义均未升级或丢失。readiness sourceMatches=true / releaseReady=false；required 退出 1 保留。
- continuityAccepted / physicalOutputVerified / capabilityAccepted 仍 false；报告明确音画未校准与连续性能力未验收。跨轮时长不被当作性能提升，历史双事务缺失字段仍未关闭。

## 本轮发现与处置

1. 原“完全断流不是必要条件”超出单变量对照可支持范围：两场景仍共享第一次停流。已收窄为第二次故障无需配置完整 5 秒停流亦可复现，并明确不能排除首次停流或此前错误状态作用；针对性复查通过。
2. 原“cancelCause=3 是回环接收错误分支”归因过窄：`YlHlsMediaProxy.swift` 的 `.failed` state 回调（305 行）、receiveRequest error（317 行）及 monitorDisconnect error（419 行）均使用 3，原始 trace 无法唯一辨认具体回调。已同步收窄报告与 high-boundary 脚本/JSON 的 interpretation 为连接失败或接收错误，并明确现有 trace 无法区分具体回调；针对性复查通过，无需改生产代码或补跑设备。

## 结论

上述两项表述问题均已修正并完成针对性复查，未发现尚未解决的新增阻断性问题。原因仍只确认外部表现，不能证明 AVPlayer 私有惩罚机制或安全生产修复；两预算严格失败及发布缺口继续保留。三份完整 xcresult 的最终分卷归档逐成员验证由主执行者完成，本复审已核查原始摘要与证据绑定，未把尚未完成的最终归档校验列作已通过。
