独立复审 /root/same_resource_review：本轮仍失败，不能确认修复。无原始字段补写或关联掩盖。

逐条运行现有校验：normal 413条trace唯一边界异常为C459…/request4。任务成功、HTTP200、8418字节、服务器148匹配，但第一事务responseStart/responseEnd缺失；第二事务完整不能补齐或证明重试原因。

CA8E…/request63因下游EOF取消，寿命4.253ms，之后2.510ms完成task cancellation；无响应/body/send/server correlationID。指标无request-start不足以证明实际网络绝无发送。

63与62同proxyID/resourceToken，63在62取消后7.061ms、任务结算后5.847ms准入。确认此前取消后出现新同URL请求；新请求也取消、无后续成功同资源请求。62的服务器64、高档640×360分片network-period-5/chunk-1-00001.m4s不能回填63。

服务器独立重算414accepted/414parsed，零未解析/未关闭，correlationID无重复。仅排除已记录listener漏解析，不能确定首事务连接、FIN/reset或AVPlayer关闭原因；不跨端时钟相减。

normal原回执仍false/ValueError，device-export与原始分析文件一致。不支持修复、因果或验收升级。
