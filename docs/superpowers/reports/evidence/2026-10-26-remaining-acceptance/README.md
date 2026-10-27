# 本轮证据索引（2026-10-26—27）

- `validation-results.json`和两端`*-runtime/`：原始综合验收与完整失败/跳过，未被补验替换。
- `native-focused/`：修订后重新构建的9次定向测试及身份检查。
- `*-coverage-reconciliation.json`：逐一身份核对后的跨次覆盖，不是单次全套通过。
- `public-abr-original/`：macOS三轮有效采集及iOS首轮三次设备关闭启动失败。
- `public-abr-ios-retry/`、`public-abr-android/`：补验采集；capability/physical/baseline认证均为false。
- `last-stages/`：Android API36 arm64 TV只读模拟器身份、结束清理与执行记录。
- `android-jvm-original/`：原始563项JVM输出；`rtmp-jvm/`保留首轮burst不足量失败，`rtmp-jvm-retry/`包含既有4Mbit/s CBR协议下4/4通过及完整服务清理。
- `consumer-logs/`：五种当前源码消费者的构建、实际链接、局部兼容设置和环境信息；发布dry-run完整日志单独保留。
- `review.json`：一次综合复审及限于发现修复/新增测试约定修订的增量审查，后续定向执行结果由实施者补录。
- `implementation-snapshot.json`：较早原生ABR诊断所用工具；`implementation-final.json`和两份native-tests快照明确区分后续修订。
- `source-delta.json`：与旧发布台账相比的57个产品源码变化；产品源码身份不覆盖测试、工具或机器环境。
- `readiness/`：两个结构入口退出0，两个require-ready退出1；最终sourceMatches=true、releaseReady=false。
- `runners/`：本轮临时编排脚本归档，用于追溯命令及测试源配置，不是产品功能或通用发布工具。

`SHA256SUMS`覆盖本目录除清单自身外的全部文件。日志使用gzip保留；不提交大体积构建产物或完整xcresult二进制目录，运行摘要、用例树与必要能力附件已保存。
