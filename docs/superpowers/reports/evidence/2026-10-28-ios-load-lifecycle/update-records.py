from pathlib import Path
import json,hashlib
report=Path('docs/superpowers/reports/2026-10-28-ios-load-lifecycle.md')
report.write_text('''# iOS 公开 Load 生命周期与同候选网络取消验收

基线 `6b699713`，分支 `codex/abr-recovery`。继续已授权剩余项，采用系统排障和集中验收。[完整原始证据](evidence/2026-10-28-ios-load-lifecycle/)保留阶段源码、失败与最终完整 xcresult。仅本地测试，不发布。

## 本轮完成

新增真实原生 typed public `host.load` 生命周期合约：原 Load 媒体代理经历跨源跳转并永久剥离合成凭据；新的非法 MPD 在提交前失败时，原 session、item、loader 与剥离历史保持，后续请求不再发送凭据；成功的新 Load 创建独立上下文，用自己的新凭据请求原始资源，跨源及返回请求不带凭据，旧 loader 被取消。用特定 Range 区分受控跳转与 AVPlayer 预读。此处覆盖提交前失败，未证明提交后失败回滚，也未经过 Dart 桥接。

新增同一 DASH 候选实际网络取消合约：先通过公开 Load 提交同 URL 活跃会话，再让真正 AVPlayer 准备恢复 candidate.asset。仅候选请求带测试专用 X-Fixture-Hold 头，受控源发送有效初始化媒体的前 64 字节并挂起尾部；当前播放会话使用完整响应。候选自己的代理出现部分传输及活动任务后，以真实跨源跳转改变共享凭据上下文，使原票据失效。

最终 macOS 与 iPhone 附件均记录取消前 receivedBodyBytes=128、activeTasks=2、activeConnections=2。断言确认候选取消、detach、无 item 返回、discard 后不能再 takeLoader；源预算仍为1，候选任务/连接/pending sends归零，取消完成回调发生，完成数等于接纳数，源观察到全部挂起连接的对端结束。原公开会话 session/item 保持，通过其媒体代理仍完整取回 segment。

带宽窗口用于合成发票，网络和 AVPlayer 候选准备为真实执行。当前结果证明取消回收及已提交会话的媒体可读性，不代表自动高档恢复或实际音画、帧时间连续性。本轮未修改生产播放器或诊断恢复算法。

## 复审修复及失败记录

综合复审发现测试服务器仅解析首个 TCP 分片、只观察一次接收，可能过早响应并漏记 EOF；还指出最初的 sibling loader 不足以证明真实已提交会话。新增分片头与尾随字节测试先复现失败，再将服务器改为最多16KiB完整头解析、持续读到EOF/error，并在锁内检查stopped与登记连接，避免关闭后漏入连接。已提交会话证明改为真实 host.load 与媒体回读。

强化测试首轮遗漏媒体 Content-Type，导致等待候选部分数据超时；补回明确 MIME 后同样的1.5秒等待与2秒准备期限通过。没有单独证明 Foundation 内部缓冲机制，不能将推测当作产品根因。取消前快照改为实际读取并附入 xcresult，不再仅因等待函数返回就赋成功值。针对修复的只读复审未发现剩余阻断问题。

完整保留9份 xcresult：targeted 为测试类型名错误的编译失败；targeted-typed 为初版2/2通过；macos-contracts 为复审前187/187通过；fragment-red 为服务器分片/EOF红灯；review-fixed 为测试请求缺少headers参数的编译失败；review-green 为强化测试2通过/1超时；mime-fixed 为修复后定向3/3通过；final-macos-contracts及final-device-contracts为最终矩阵。编译错误不作为产品缺陷复现。原始编译/链接警告未删除。

## 最终统一验收

最终同源码 macOS **188/188**、iPhone **213/213**，均0失败/0跳过；逐项核对唯一测试身份和完整预期集合（macOS7类、iPhone8类）。iPhone先前断开，用户确认连接并解锁后完成真机运行。23份源文件绑定最终制品，复审前快照单独保留。

消费者夹具46项：45通过、1历史 focused evidence 缺失跳过；镜像声明 iOS850/macOS894通过，生产声明及历史迁移来源检查通过。网络工具本轮无修改，复用[上一轮124项通过证据](2026-10-28-ios-credential-race.md)。公共Pigeon/Dart协议和Android未变，本轮未运行完整Flutter/Android矩阵。

准备2秒、票据5秒、双8秒资格窗口、955000bit/s、最多2次、500/1000ms退避均未放宽。没有新增长素材运行；[上一轮pause/seek长素材到EOF但仅320宽的失败](2026-10-28-ios-public-transport.md)保持失败。旧终末停顿不恢复为待办。

## 发布台账与剩余项

生产源码未改变，哈希保持 `745362ff8d58a76ae2fe185ba8b91708b15c04a687f00ef3925363f02b463ba7`。台账新增本轮证据并细化后续行动，102行实施/验收状态不变，releaseReady=false。iOS CAP-ABR直接引用已达20条，本轮替换上一轮直接索引，上一轮报告由本文链接且仍在总证据表及历史档案中，不扩大结构上限。

仍待：完整公开Dart凭据竞争与提交后失败边界、原配置稳定自动恢复、暂停/跳转后640高档恢复、替换新帧空档及物理音画/字幕连续性、多设备与最低系统、DRM/Dolby授权资源。已完成的是上述原生Load与受控同候选取消合约，不能据此关闭整体ABR/DASH验收。

历史18组、4732个清单文件已逐项核对且未改写。完整归档和台账最终核对结果见证据目录中的final-verification.json与readiness/results.json。未合并、推送、打标签或发布。
''')
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());key='ios-load-lifecycle-20261028';old='ios-credential-race-20261028'
d['evidence'][key]=dict(kind='report',path=str(report),sha256=hashlib.sha256(report.read_bytes()).hexdigest())
for row in d['rows']:
 if old not in row['evidence']:continue
 if len(row['evidence'])>=20:row['evidence']=[key if x==old else x for x in row['evidence']]
 else:row['evidence'].append(key)
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':row['nextAction']='qualify-dart-credential-races-postcommit-failure-high-output-original-auto-recovery-and-physical-output'
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
p=Path('docs/superpowers/plans/2026-10-28-ios-load-lifecycle.md');p.write_text(p.read_text().replace('- [ ]','- [x]')+'\n完成记录：[统一验收报告](../reports/2026-10-28-ios-load-lifecycle.md)。生产无需修复；新增3项原生合约并修复测试服务器，最终iPhone213/macOS188通过；整体未完成项继续保留。\n')
