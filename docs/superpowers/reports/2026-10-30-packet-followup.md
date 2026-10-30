# 包级端点分类修复与一次问题复现采集

基线 `a346fb4e`，承接[包级采集报告](2026-10-30-packet-evidence.md)。继续排查缺端点／缺响应事务时，发现并修复包级归因丢失既有分类的问题；完成一次120秒真机复现采集。播放器生产源码、恢复预算和严格验收门槛不变。

## 已修复

事务层对空 token 已区分 `endpoint-unavailable`（端点字段缺失）和 `unsupported-endpoint`（字段齐全但不支持当前编码）。原包级归因对所有空 token 一律输出 `endpoint-unavailable`，将“编码不支持”错误描述成“字段缺失”。现在直接复用已验证事务的 binding，不新增判断或兼容分支。

新增回归先失败于上述分类错误，修复后8项受影响归因测试通过。两处旧测试的空 token fixture 同步使用真实上游契约的 `endpoint-unavailable`，不再构造“空 token 且 bound”的不可能输入。精确关联头仍只建立任务级观察，事务没有可用端点时 packetObserved 保持 null。

## 新采集事实

使用与前轮相同的 iPhone 制品、120秒初次降档／高档后触发5秒停流场景。一次新采集用于寻找此前的间歇问题，没有循环重跑直至通过。

- 原生退出0，严格回执 passed=true、errors=[]，制品前后指纹一致。
- tcpdump 正常停止，持续132.064秒，14,128个包，kernelDropped=0，complete=true。
- 415条TCP流均匹配服务端接纳记录；413个代理请求全部有精确HTTP关联及唯一事务连接关联。
- 高档基线在设备36.749秒触发，45.370秒再次降档；两次生产恢复安装，随后发布高档帧。
- 8个非成功请求中，5个为cancelled（cause3），3个为sendFailed；每条均只有一个事务，endpointFields=15、responsePresent=true，并能关联已接纳连接和抓包流。

本轮未复现多事务、缺端点、缺响应对象或服务端未接纳的包流。不能将本轮下游发送失败或取消的包序列套用到历史缺响应事务。历史未知接收和失败不回填，rootCauseEstablished、unsentProven、物理输出及能力验收均不提升。

## 证据与台账

[证据目录](evidence/2026-10-30-packet-followup/)保留原始pcap（gzip）、原始请求/事务/帧/策略、完整回执、采集命令及输入指纹、分类测试红绿日志。`diagnosis.json.gz` 提取8个非成功请求的原始边界、连接、包序列和服务端接纳记录；分析脚本一并归档。原始pcap仍含自有测试端点和HTTP头，不作为脱敏导出。

原始pcap SHA-256：`552e006bccefa06470b8b1c6a4929dfaf442eea9de2ecbb562dcf3ddc93e0915`。完整xcresult留在 `/private/tmp/yl-packet-followup/media.xcresult`。

台账CAP-ABR/iOS最新直接引用替换为本报告，前轮报告全局定义和历史失败保留，所有102行的implementation/verification/acceptance状态不变。下一步仍需在完整抓包下复现缺端点或缺响应事务，另有物理音画连续性、设备和授权缺口；本次分类修复不构成这些问题的完成声明。
