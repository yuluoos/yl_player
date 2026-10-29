# 验收原始证据

完整保留全部xcresult（含红灯和媒体失败）。较大tar.gz按15MiB顺序分片，按parts.json中的顺序连接、核对组合SHA256后再解压。普通.gz还原为raw-provenance.json记录的原始字节。SHA256SUMS覆盖所有归档文件；原测试制品绑定见source-identity与各receipt。

本轮使用已存在的本地素材和受控回环网络合约，没有新增120秒ABR媒体采集。凭据上下文/票据红灯、同步安装竞争红灯、v2证据验证器红灯均保留；不把阶段策略/帧校验通过等同EOF、完整ABR或物理音画连续性验收。
