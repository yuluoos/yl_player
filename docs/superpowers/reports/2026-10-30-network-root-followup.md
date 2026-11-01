# iOS 间歇网络续查：精确任务关联与入站空窗

基线 `6698ff7e`，承接[上轮包级复现](2026-10-30-packet-followup.md)和[事务连接证据](2026-10-30-transaction-connection-evidence.md)。本次复现了真实超时，补齐“代理请求—Foundation任务—系统连接—TCP序列”的证据链。**已解释这次缺端点/缺响应对象的直接机制；另外在Nextin重新开启轮捕获首事务复位后重试成功；导致网络滞留/握手切换的具体组件及历史实例仍未全部闭合，不能标记根因调查完成或能力通过。**

本轮产品源码仅增加 DEBUG、显式启用的诊断字段；另外修正测试服务器的监听队列容量，处理器接入上限仍为8。没有修改播放器超时、连接数量、重试、恢复策略或验收门槛。

## 已确定的失败机制

`task-linked` 使用本轮重建制品。256个代理任务均取得独立Foundation标识，并全部匹配到本测试进程的CFNetwork日志。11个目标任务为15秒超时：5个端点完整但事务的response对象为空，6个端点全空；这轮没有双事务任务。原生退出65，严格回执passed=false，错误包括代理请求关联不完整及事务连接证据不完整。没有将这些失败重新解释成通过。

Mac `en0` 抓包在相对51.224412至76.057545秒之间，连续24.833133秒没有来自iPhone的包；同一窗口仍记录112个服务端包。抓包共8,315包，零内核丢包、正常停止，capture.complete=true，SHA-256为 `69b71a6f54b28634e6d9605870a211e327d88ab1f5bd30e70fc0ce31332ae352`。抓包完整表示采集过程完整，不证明物理链路交付。

服务端心跳最大间隔0.505902秒，252个接入全部有请求记录，没有拒绝或丢弃记录。配置的停流实际只发生在profile 48.737764至53.737764秒，持续5秒；不能把约25秒的入站空窗归为这段5秒夹具停流。播放最终停在57.894748秒，hostStatus=failed，completed=false。

### 缺端点实例：请求46

精确身份为代理 `DC38FA82-CC99-445A-BDCF-DFB0AFE248B7`、请求46、Foundation任务 `<8534a323-ea8b-40af-b73f-f333be1dee87>.<46>`。日志明确该任务设置Connection 430；其TCP总结给出 `192.168.50.121:51752 ↔ 192.168.50.196:60725`，初始SYN序号3284013542。

1. iPhone同一连接记录13次SYN发送尝试，2秒时报connect_stalled，约15秒任务以NSURLErrorDomain -1001结束。没有应用取消来源；后续连接清理不是最初原因。
2. 同一元组、同一SYN序号在Mac原始pcap出现。前10个SYN在96微秒内到达，TCP timestamp数值从4282354252增至4282356953，其间隔与客户端前2.701秒的重传日志相符。另有两个SYN随后到达。不能仅按请求顺序或时间相近建立此关联。
3. Mac产生SYN-ACK，ack=3284013543；随后出现客户端RST，seq=3284013543，没有HTTP请求字节，也没有服务器accept记录。请求超时后迟到的握手报文无法建立该连接。
4. Foundation收集指标时连接尚未建立，系统明确记录“在未连接的nw_connection上读取connected endpoint”。因此端点全空的直接原因是握手未完成，**不代表未发包，也不是本例中的应用层排队未启动**。

[可重算证据](evidence/2026-10-30-network-root-followup/task-linked/failure-chain.json.gz)保存日志行、精确元组、序列及TCP timestamp；`summarize_failure.py`从原始pcap及本进程日志生成该链。iPhone和Mac墙钟存在偏差，分析使用同端相对时间及序列关联，没有直接相减跨设备墙钟。

### response对象为空实例：请求41

Foundation任务 `<ce038b5e-64d4-4db3-bfc8-58fdb8c323ac>.<41>` 明确使用Connection 419；精确HTTP关联标识 `827341A1-B326-4FFE-92A5-030F1226A7E4` 对应服务器request/connection 210。

CFNetwork已经收到HTTP 200，指标记录584字节响应头，但正文为0；随后15秒超时，事务response对象为空。服务器记录profile 49.012862秒开始，53.764383秒完成8,391字节正文写入，hold约4.735秒、写入无失败。服务端写入成功不保证客户端收到正文。**responsePresent=false不能被解释为从未收到响应头。** 这与历史首事务响应字节为0的案例不同。

### 成功任务的首事务未接纳：重新开启Nextin后的请求4

`nextin-on-authorized`捕获代理`D039FBBF-B53C-4916-9AB2-6331340B1BCE`、请求4、Foundation任务`<96565444-eab1-422f-85c1-0aa3e053a4e7>.<4>`。首次Connection 366的元组为`192.168.50.121:52437 ↔ 192.168.50.196:49572`。以下均由精确标识、元组和序号相互对应，而非仅按时间猜测：

- Mac先对客户端SYN 53008520两次回复SYN-ACK，服务端ISN为2712525058。
- 客户端第三个相同SYN随后与ACK及310字节HTTP请求集中到达；ACK指向2712525059，HTTP中含精确关联标识`53AFB5B1-7F00-442C-ABE5-A8209BD95692`。
- Mac在约13毫秒后对该第三个SYN改用ISN 2683161692，并发送seq=2712525059的RST。Mac内核日志显示Python:66104对应socket此时进入SYN_RCVD，最终在该状态关闭，没有进入服务器接入台账。
- iPhone记录同一Connection 366在ESTABLISHED收到该RST并报告ECONNRESET。CFNetwork对**同一任务**记录reason(7)允许重试，首事务requestBytes=310、responseBytes=0；Connection 367第二事务成功，最终任务成功。首事务的请求已到Mac抓包点，未进入accept/request台账不代表未发送。

[retry-chain.json.gz](evidence/2026-10-30-network-root-followup/nextin-on-authorized/retry-chain.json.gz)保存完整对应链，另有原始TCP选项和限定端口的内核摘录。此例与历史“成功任务首事务未接纳”的形态一致，已解释其直接复位/重试机制；不能把新的任务身份写成历史任务的精确追踪。

**进一步机制仍为推断：**测试服务器监听队列为8，本机`syncookie=1`、`soqlimitcompat=1`。同一时刻Mac日志记录半连接数达到3；Apple公开代码按此配置计算的SYN-cookie门槛也为3。第一组ISN解出的cookie选项恰好符合客户端的MSS1460、window scale6、SACK及无ECN，支持“先走SYN-cookie，再因队列回落使重传SYN创建普通socket，旧ACK命中新socket导致复位”的解释。[Apple TCP队列条件](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/netinet/tcp_var.h)、[SYN-cookie实现](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/netinet/tcp_syncookie.c)。

参考源码不等同于本机运行的`xnu-13432.1.9~1`；没有对原始重传顺序做独立逐包重放，所以不宣称修复了系统内核竞态。随后在本机及实际FixtureServer中验证了小监听队列会触发SYN-cookie，证据与修正见下节。普通用户TCP统计全零，同时`disable_access_to_stats=1`，不能据此认为cookie从未发生。管理员读取已成功：发送计数372、接收计数125、监听队列溢出0。这些是主机累计计数，不能直接归属某次播放；发送计数也不等同于包数。`pfctl -si`因权限不足失败，未修改PF规则。

### 实际服务器的监听队列回归与修正

只在Mac本机`lo0`运行的受控实验，在开始accept前排入8个连接，比较监听队列8与32。第一次采集过早停止：内核过滤器收到包，但tcpdump捕获为0；此轮仅保留计数线索，**不作为有效抓包**。改为即时采集并留出1.2秒收尾后，各轮均捕获64包、内核丢包0：

| 受控对象 | 监听队列 | 接入数 | SYN-cookie发送计数增量 | 抓包观察 |
| --- | --- | --- | --- | --- |
| 独立本机监听器 | 8 | 8 | +2 | 前7个普通SYN-ACK，第8个为cookie格式 |
| 独立本机监听器 | 32 | 8 | 0 | 8个均为普通SYN-ACK |
| 实际FixtureServer旧配置 | 8 | 8 | +2 | 回归断言失败，退出1；64包 |
| 实际FixtureServer修正后 | 32 | 8 | 0 | 同一回归通过，退出0；64包 |

本机cookie报文的选项顺序与真实失败首事务的第一组SYN-ACK一致；同一次实验1个cookie报文对应发送计数+2，因此不把计数当包数。这证明测试夹具在许可的8连接突发下也会进入SYN-cookie路径，不依赖iPhone或Nextin。

据此将`tool/playback_network/network_profile.py`的监听队列由8改为32；`process_request`中的8处理器上限及拒绝记录保持不变。增加的是有界TCP等待队列容量，没有放宽处理线程上限、改变故障曲线或修改系统TCP/VPN/PF配置。回归通过实际的 `net.make_server` 创建监听器，测量八个连接的接入数及内核计数增量。

受影响的服务器单测37/37通过，涵盖接入限制、整形和关闭。此前诊断身份/包解析/设备导出的结果复用，未重跑无关全量套件。该修正消除了受控8连接实验中的非预期cookie路径；**不代表25秒无线空窗已经解决，也不是对所有系统负载下零cookie的承诺。**

修正后使用相同 iPhone 制品完成了一次不抓包的播放验证。最终位置为 120.025036 秒，播放器报告完成，严格回执通过。418 个任务全部匹配到本进程日志，本轮目标异常为 0。此前带抓包的尝试在系统授权阶段超时，播放未启动。[监听队列与真机验证摘要](evidence/2026-10-30-network-root-followup/listener-verification-summary.json)

### Mac侧无线线索与用户确认

Mac时间02:54:40、45、50、55的四条驱动 `MonitorTimer en0/5000` 记录均为I0，出站O分别391、746、1122、1181；02:55:00记录I4580。该窗口RSSI约-43至-45，筛选的日志未观察到link down/up、deauth、漫游或重置事件。电源日志选定窗口未见Sleep/Wake，服务端心跳也持续。

10 月 31 日从 Mac 系统日志重新提取了故障窗口及恢复时刻。02:54:42、47、52、57 四个 HighBand 采样中的 `rxDataUcastMbss` 均为 0，同期每个采样均有信标和组播计数。02:55:02 的单播计数恢复到 1192。系统记录了三个 `broken-backhaul` 事件，事件代码分别为 3、4、0。系统探测服务在相应时刻发布了相同代码。这里保留原始代码，具体触发原因仍缺少 AP 侧记录。[无线接收计数与系统探测日志](evidence/2026-10-30-network-root-followup/wireless-receive-window.json)

这使Mac无线接收路径及AP到Mac的链路成为重点，但驱动计数是实现相关的观测，不能据此判定每个物理无线帧都未到达，也不能据此确定AP、Mac驱动或iPhone扩展中的哪一处滞留。没有空口/AP观测时，不声称发现了特定无线驱动缺陷。

用户明确确认失败期间没有移动手机、切Wi-Fi或操作路由器，设备保持原位；随后确认iPhone开启 **Nextin**。是否绕过局域网尚未确认。客户端日志标为en0/Wi-Fi、proxyConnection=false，并不能排除VPN扩展影响。Mac当前路由直达iPhone的en0，HTTP代理配置排除192.168.0.0/16；Surge CLI也显示Mac增强模式开启。这些是事后配置观察，不是失败时扩展参与/未参与的证明。系统代理例外不能单独排除增强模式，[Surge官方说明](https://manual.nssurge.com/features/enhanced-mode.html)将两者区分。没有据此更改Mac代理设置。

## 对照运行

场景均为120秒、首次降档、恢复高档后5秒停流、close连接、生产自动恢复，命令及制品哈希保留。旧制品轮次早于音频释放修复，不作当前main验收；`task-linked`、`nextin-off`、`nextin-on-authorized`为本轮重建的同一份Debug制品，三轮binaryHashes完全相同。

| 轮次 | 实际结果 | 解释边界 |
| --- | --- | --- |
| media，历史制品 | passed=true；420任务、422流、13,293包；零内核丢包 | 未复现目标 |
| cfnetwork，历史制品+CF3 | 授权超时，播放与抓包未启动；passed=false | 不计有效播放 |
| cfnetwork-only，历史制品+CF3 | passed=true；411任务；未抓包 | XCTest标准输出未提供精确任务关联 |
| cfnetwork-authorized，历史制品+CF3 | 重新授权后passed=true；418任务、12,686包，零内核丢包 | 未复现目标；CF详细日志只覆盖前约46秒，不能宣称完整 |
| task-linked，新制品+CF1+本进程日志，Nextin开启 | passed=false；256任务全部匹配CF日志，11个超时目标，24.833133秒入站空窗 | 首次准确绑定真实失败；具体滞留组件未定位 |
| nextin-off，同一新制品，用户确认断开Nextin | passed=true；416任务全部匹配CF日志，无目标异常；13,775包、418流，零内核丢包 | 完整播放120.020482秒、2次恢复；最大入站间隔2.406065秒；一次成功不能证明Nextin因果 |
| nextin-on，用户确认重新连接Nextin | 授权等待超时，播放与抓包未启动 | 不计有效播放，失败回执保留 |
| nextin-on-authorized，用户要求重新授权后 | 原生退出0，播放完成；严格passed=false；415任务全部匹配CF日志，1个双事务目标；13,582包、418流，零内核丢包 | 最大入站间隔2.7523秒，没有长空窗；因成功任务首事务指标/连接关联不完整而失败 |
| listener32，队列修正后申请抓包 | 授权超时，播放未启动 | 无包级结果 |
| listener32-client，队列修正后只采集应用日志 | 原生退出0，严格回执通过，418个任务全部关联，播放完成 | 本轮无pcap |

`nextin-off`采集137.684761秒，pcap SHA-256为 `7377c0be33895abb789808b960aacb6a81fa44fabd6ae061773ca6c408357653`。重新开启轮采集136.555237秒，pcap SHA-256为`97578c241bc9d12f4662e289374a43da1745ec0b804bf66a28d910b129afc9ea`，播放120.020847秒完整结束。开启/关闭/重开未稳定重现**同一**异常，不能宣布Nextin因果成立。

## 诊断实现与最小验证

- DEBUG连接sidecar由v2升级v3，增加可空foundationTaskID。只接受已观察到的`LocalDataTask <UUID>.<正整数>`完整格式，输出小写标识；未知格式保持null，不导出可能含URL的任意description。Foundation description不是公开稳定身份契约。Python读取器保留v1/v2，绝不补造旧身份；既有连接绑定与验收规则不变。
- 原生测试夹具在`YL_ABR_PROBE_CLIENT_LOG=1`时，以`OSLogStore(scope: .currentProcessIdentifier)`导出本进程CFNetwork/network日志，单次上限100,000条/16MiB，超限明确失败。设备导出列表增加可选client-network.jsonl。CFNETWORK_DIAGNOSTICS=1由隔离xctestrun配置；不是默认开启的产品日志。
- Python身份测试先红后绿，13/13；包证据22/22；设备导出6/6。相关代码未再变化，复用这些结果。
- iPhone原生身份测试先红（缺v3字段），之后三个定向测试全部通过，覆盖强制连接关闭、真实取消及排队取消。增加本进程日志后构建通过，单独运行强制关闭测试通过，并验证日志PID全部为当前进程、包含精确Foundation标识。
- 控制夹具中的同任务CF日志显示reason7重试及首事务无响应，这是**服务端强制关闭夹具**的证据，不移植给历史媒体案例。
- 最终当前夹具同步检查通过：iOS 900、macOS 944；没有宣称macOS本轮原生运行或重跑全量套件。

重新构建后，复制或修改隔离测试产品的xctestrun `EnvironmentVariables`，设置`CFNETWORK_DIAGNOSTICS=1`和`YL_ABR_PROBE_CLIENT_LOG=1`，再执行归档commands.json中的task-linked/nextin-off命令。源文件指纹见followup-inputs.json；每轮receipt.binaryHashes固定具体产品。`diagnose_tasks.py <运行目录>`生成精确任务到系统连接的日志索引；connectionIDs可能包含请求曾等待的连接，不能不经日志核对就将所有候选连接当作实际使用。

## 取证边界与尚未完成项

历史 `media-presence.xcresult` 中C667在ESTABLISHED状态收到RST是真实线索，但旧日志无精确任务身份，目标附近有多个并发任务，无法可靠绑定。历史毫秒级取消且缺端点的实例，也不能被本次15秒握手超时统一解释。当前状态如下。

1. 约25秒滞留未随Nextin重开稳定复现，需要AP或另一网络路径的同步证据才能区分无线/扩展/驱动位置。Nextin因果未成立。用户确认暂时没有 Mac 有线连接条件，AP 型号及管理日志可用性也不确定。无线计数已将故障定位到单播接收路径，AP 转发与 Mac 驱动仍待区分。
2. 首事务复位机制已精确复现，实际服务器的 SYN-cookie 触发已受控验证。监听队列修正后的真机场景也已完成，结果见上文。
3. 历史快速取消尚未精确复现；历史成功任务也没有原始精确绑定，不能把新实例标识回填旧实例。
4. 当前CAP-ABR及物理输出验收仍开放。全部102行实现/验证/验收状态保持不变，只更新证据、源码指纹和下一步动作。

本轮管理员授权已成功。曾尝试设备`log collect`并指定本测试PID，但设备收集没有遵守PID筛选，产生了包含其他进程的archive；发现后只保留已核实Runner PID3454的日志，并删除未筛选导出及整份设备archive。此后改用测试应用自己的OSLogStore，后续不收集全设备日志。不能把这次尝试表述为从未接触过其他进程日志。归档的 Mac 无线材料为故障窗口的选定计数及系统探测事件。

[证据目录](evidence/2026-10-30-network-root-followup/)保留失败和成功回执、原始自有端点pcap、客户端本进程日志、任务索引、服务端记录、红绿验证、命令、指纹及可重算脚本。原始pcap与本进程日志包含自有测试地址/URL，不是脱敏公共导出；10 月 31 日续查时，临时目录 `/private/tmp/yl-network-root-20261030/` 已不可用。仓库保留了前期失败样本的 pcap、客户端日志和服务端证据。监听队列修正后的验证结果依据上轮实际读出的命令输出登记，最后一轮原始回执、xcresult 和本机队列实验 pcap 未能补回。只读尝试从 iPhone 重新导出时，CoreDevice 返回连接失败（4000）。
