# iOS 自有 HTTP 服务包级证据

本轮接续工作区未提交的包级采集实现，完成信号修复后的真机验证、完成判据测试和证据归档。未修改播放器生产源码、恢复预算或验收门槛；未发布。

## 实现与边界

`abr_accesslog.py --packet-interface en0 --transaction-connections --connection-mode close` 在自有 IPv4 HTTP 服务启动后、播放前启动固定参数的 tcpdump。macOS 系统窗口负责管理员认证；脚本不读取密码。采集限制为该主机及临时服务端口，180 秒时限、内核 64 MiB 文件上限。结束时必须正常退出、保留捕获包数及零内核丢包统计，且解析包数一致，才能记录 complete=true。

`packet_evidence.py` 解析 Ethernet/IPv4/TCP classic pcap，保存匿名连接 token、标志、序列号、确认号、载荷长度及精确关联 ID。支持分割、乱序、重传请求头；截断、流缺口、冲突重传及连接复用歧义不推断成功。事务只按唯一端点 token 关联；缺端点时精确 HTTP 关联头只建立任务级观察，不按事务顺序分配。

工作区已有的信号修复在特权 worker 启动 tcpdump 前解除继承的 SIGINT 屏蔽，使停止信号可正常刷新输出和结束统计。本轮增加完成判据测试，覆盖正常结束、内核丢包、缺少统计、到期及强制结束五种情况。

## 真机结果

使用已有 iPhone 测试制品 `/private/tmp/yl-ios-remaining-20261029/build/Build/Products`，120 秒 `initial-downshift-trigger-control-v1` 场景，预算与生产恢复策略不变。制品逐文件指纹及采集输入见原始回执与命令；本轮正常运行的 binaryIdentityUnchanged=true。

| 轮次 | 结果 | 保留事实 |
| --- | --- | --- |
| 上轮初次采集 | failed | 播放退出 0，但 tcpdump 被强制结束，exitCode=-9，无完整统计；14,207 包、422 条流、420 个请求的已有观察不能使整轮通过 |
| 本轮沙箱启动 | failed | PermissionError，尚未启动播放及抓包；保留独立回执 |
| 本轮授权后采集 | passed | 原生退出 0，errors=[]；14,296 包、416 条流、414 个请求；414 个请求和全部事务均完成包级关联 |

授权后采集正常 stop-requested，tcpdump 退出 0，持续 131.622 秒，kernelDropped=0，解析包数与捕获统计一致，complete=true。原始 pcap SHA-256：`817f0a74efbf88795d5b0b859ca4e34f50380b29d67bff92bbd3db6d04d1c76b`。

本轮设备高档基线触发时间 37.493 秒，再次降档 45.450 秒；生产恢复安装两次，随后发布高档帧。既有采集器的触发、策略、恢复、帧观察检查通过。设备和服务器使用各自时钟，不将两者直接相减。

本轮没有复现缺端点或双事务缺响应；全部请求可关联不能解释历史未知事务，也不能证明历史物理包接收。`unsentProven`、`rootCauseEstablished`、`capabilityAccepted`、`physicalOutputVerified` 均不提升。包级观察和发布帧不等于物理音画连续性验收。

## 验证与归档

复用前轮未变化实现的解析、归因、worker 时限/文件限制、连接歧义及信号修复测试日志，不重复执行全套。本轮只新增运行一个完成判据测试（五个分支），通过；并执行上述一次授权后真机验证。先前日志来自接续任务的 `/private/tmp/yl-packet-evidence`，按原样归档，不宣称它们在本轮重新运行。

[证据目录](evidence/2026-10-30-packet-evidence/)包含三轮回执、两轮原始 pcap、TCP/HTTP 摘要、事务与服务器记录、原始帧/策略观察、命令、源码指纹及测试日志。大文件以 gzip 无损保存，`archive-manifest.json` 记录归档文件 hash。原始 pcap 含自有测试端点与 HTTP 头，不是脱敏导出；JSON 包摘要不输出地址、端口或请求路径。xcresult 保留在 `/private/tmp/yl-packet-evidence/`，不导出无关设备诊断。

发布台账登记本报告及后续动作，保留所有 102 行 implementation/verification/acceptance 状态。CAP-ABR/iOS 已达到 20 条直接引用上限，因此以本报告替换最新直接引用；[前轮事务连接报告](2026-10-30-transaction-connection-evidence.md)及其全局证据定义仍保留。后续需在完整包采集下复现缺端点/缺响应事务，继续保留最低系统、其他设备、真实网络、授权素材和物理音画验收缺口。
