# 合并复核

独立 reviewer 对 P03 与主目录重叠文件、seek/FIFO/reactivation、P04 live refresh/exclusive replacement、iPhone collector 与拆分后的路径做了只读复核，未发现确定的合并阻塞项。

原生验证发现两个旧 retained-transaction 断言不符合 P04 exclusive replacement 契约后，进行了第二次只读复核：构建前 inactive 与 clears + 1 有明确生产代码依据；网络恢复改为等待实际 host active（旧对象保持 inactive）且命令队列清空；暂停、两种 seek、原会话身份、无错误及真实出帧断言均保留，未掩盖产品问题。需配合最终重跑结果读取。

历史 iPhone 证据不等同于当前合并构建真机验证。
