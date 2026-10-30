# 独立综合复审：触发式再次降档

复审基线：`c7342f8c`；审阅对象为本轮未提交差异及新增触发器、测试、计划、报告和台账。复审遵循 consolidated-acceptance 与 requesting-code-review；只读生产/测试来源，运行宿主小范围定向验证，不启动设备，不改变预算或既有严格验证函数，不发布。

## 结论

发现两项重要工具缺陷，均已在本轮修复并完成针对性复审；当前未发现尚未解决的重要代码问题。该结论只说明所审修改可保留，不代表能力验收：三轮原始严格结果仍为 0/3，预算耗尽后恢复高档、历史上游超时/双事务归因、取消请求全关联及设备/物理音画缺口继续开放。最终证据归档清单、归档哈希和报告登记哈希由主代理在归档结束后核验。

## 发现及关闭证据

1. **[P1，已修复] 普通触发模式没有强制要求触发后再次低档。** 初版 `summarize_trigger` 只绑定触发前高档窗口；原生产恢复验证器的全程一次高—低—高可由第一次静态故障满足，因此新故障未造成再次低档时仍可能通过普通模式。README/计划已明确要求缺少再次降档保持失败。修复在新 opt-in 验证器中要求触发后同代际真实 320 发布帧及后续低档位置推进，保留原验证器不变。无再次低档反例已先失败、修复后通过；独立复算三份原始捕获得到再次低档时刻 67.44394958333578 / 45.19892350000737 / 75.2991458333272，与报告一致，所有 capabilityAccepted 仍 false。
2. **[P2，已修复] 服务器启动前的错误路径可能无限等待清理。** 初版在媒体服务器已创建、`serve_forever` 尚未启动时检查 profile，异常路径无条件 `shutdown()`；Python BaseServer 会等待尚不存在的服务循环，不能写出最终 receipt。控制端创建失败也受影响。修复将 profile 校验前移，并增加 `close_fixture` 区分未启动/正在运行的线程，仍关闭套接字。独立无套接字 BaseServer 复现旧等待及新立即返回；实现者真实 HTTPServer 未启动清理回归通过。

辅助文案建议：预算场景的“第2次安装”应表述为“第2次预约的唯一成功安装”，避免与 2 次预约 / 1 次安装的统计混淆。旧预算观察字段 `secondInstallElapsed` 可保留并说明其历史含义。

## 覆盖与事实核对

- 检查了 Swift 触发门状态、真实发布帧入口、一次性 Task 与会话取消、独立控制端 token/正文上限/连接截止、覆盖层边界和两种单调时钟、宿主绑定验证与清理。
- 新 Swift 只在测试夹具和两个派生副本出现；两副本仅有既有的首行 `@testable import yl_player_media_core` 迁移差异，其余与共享来源一致。预算 2 及原恢复/预算/连续性严格函数未修改。
- 复核 442 项捕获来源：修复前仅 README 与捕获时快照不同；复审修复后的宿主工具必须明确区分于捕获时版本，不应声称原捕获执行了修复后工具。原生输入未因宿主修复改变。
- 逐项复核 307 份二进制哈希和 44 份媒体原始证据哈希，均匹配保存清单。593 项生产普通文件哈希匹配；本项未代替主代理最终完整生产指纹/符号链接核验。
- iOS 257 和 macOS 232 项选定用例 expected/observed 身份完全相等，均无 skipped。保存的工具全套日志为 210 通过；消费者为 45 通过 / 1 既有跳过；宿主复审修复另有 5 项定向测试通过。
- 三原回执均 passed=false；binaryIdentityUnchanged=true、ownedProcessExited=true。原始退出分别为 65 / 0 / 0。未覆盖原回执，没有把离线专项观察替换整轮失败。
- macOS 四组 URLSession 诊断的事务数、解析数、238 请求头字节及 sessionInvalidated=true 与报告一致；报告明确指出本控制接受两连接、历史记录只有一连接，未将可行机制宣称为历史 iOS 根因。BPF 读写权限缺失记录与保留抓包缺口一致。
- 对比基线台账 102 行 implementation / verification / acceptance 未改变；本轮只追加报告定义、替换 CAP-ABR/iOS 直接引用及下一步，未见验收状态升级。

## 本次验证记录

- `review-probes.json`：旧代码两处问题的独立定向证实，以及来源/台账核对。
- `review-identity.json`：307 二进制、44 原始媒体证据和三原回执事实核对。
- `review-targeted-nonsocket.log`：独立执行 3 项无套接字测试通过，包含缺少再次降档反例。
- `review-fix-validation.json`：未启动 BaseServer 清理立即返回；三份原始帧经新触发验证器复算均绑定且实际再次低档。
- `review-fixes-red.log` / `review-fixes-green.log`：实现者新增反例先红后绿；最终 5 项通过，包含真实 HTTPServer 清理及控制端身份/重复请求测试。
- 复审者最初执行 4 项测试时，3 项通过，1 项因当前沙箱禁止 loopback bind 返回 PermissionError；此为复审环境限制，不冒充成功，也不据此重跑设备。控制端和真实 HTTPServer 测试复用上述明确对应修复版本的通过日志。

未运行设备、未修改生产文件、未推送、合并或发布。最终归档期间如运行代码再次改变，需按变更边界补做针对性验证；无需重复未受影响的原生捕获。


## 限定追加复核：高档请求重试与故障区间

本节仅核对收尾新增的 `retry-analysis.py/json`、`fault-overlap.py/json` 及其原始记录，未重做综合审查、未改源码或运行设备。独立复算证据保存于 `review-retry-validation.json`。

- 从冻结 MPD 的 width=640 Representation ID 和实际 fixture 文件重新建立完整高档资源集合，复用未修改的 `summarize_rendition_retries`。两个预算场景的 highResets 与 `retry-analysis.json` 完全相同；新 proxy 的请求 43 / 44 均为 outcome=1、cancelCause=3、source=1、POSIX 54。以同一设备时钟严格比较 `admission > downstreamTerminal` 后，两请求均无同 proxy 后续高档接纳、无同资源重试、无其他 proxy 后续高档接纳，亦无同 proxy 已在途高档请求。
- normal-zero 的严格重试摘要确实因关联不完整抛错，highResets=null；不能将该轮解释为“没有重试”。可单独引用已关联失败请求的局部事实，不能由此补全缺失的两条关联。
- 对全部高档 ID 独立计算服务器请求区间与覆盖区间的交集，匹配 `fault-overlap.json`；同时核验 requestID、correlationID、实际资源长度。预算两轮请求分别在覆盖开始前 **15.053500ms / 13.610208ms** 进入，服务器记录结束分别在覆盖结束后 **20.884542ms / 33.396625ms**。两次完整资源均 25431 字节，服务器 bodyBytesWritten 均等于 25431；代理收到/下送分别为 19456 / 16384 字节，随后上述 source=1/POSIX54 终止。
- 因为失败请求已在覆盖开始前进入，`retry-analysis.json` 的 `secondPhaseHighFailures=[]` 仅代表“服务器接纳时间不早于覆盖开始”的子集为空，不能用来排除这两个跨覆盖区间的在途失败。报告应采用 `fault-overlap.json` 的交集结论，并保留这一解释。
- 已读取 `retry-analysis-correction.json`，确认最初模板/Period 资源解析错误所得空列表被标记无效，不作为“不重试”证据。修正后的资源身份及本次独立完整文件集合复算结果一致。

拟新增结论可以保留为“当前捕获记录内，高档错误终止后未再接纳高档请求”。服务器 complete 只表示服务器应用层写出完成；区间重叠和代理部分收包不能证明所有字节抵达设备，也不能单凭此确定错误由覆盖层引起，更不能证明 AVPlayer 私有 penalty 算法、期限或未来行为。预算首轮还受后续音频中断截断观测；重复轮完整到 EOF 仍低档。两者不应混为相同观察时长。全部 rootCauseEstablished / causalityProven / capabilityAccepted 维持 false。未发现这段受限事实结论需要新增的重要修正。
