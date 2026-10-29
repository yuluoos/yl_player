# iOS 公开接口清晰度矩阵与本地地址访问修复

基线 `7c4cf933`，分支 `codex/abr-recovery`。继续已授权未完成项，沿用系统排障、测试驱动和集中验收。[原始证据](evidence/2026-10-28-ios-public-policy/)保留全部失败及完整xcresult。未发布。

## 确认的问题与修复

原生typed public host首次加载自有LAN DASH素材在首个请求前返回policy.unsupported，服务器请求为0。定位到prepareDash使用managed HTTP预检，而YlManagedTransportRestrictions只把loopback、无点名称和.local认作NSAllowsLocalNetworking允许的目标，误拒绝192.168.1.20。这是公开接口的首请求前阻断，不是对旧后端penalty-box行为的原因判定。

[Apple官方NSAllowsLocalNetworking文档](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)说明该配置覆盖IPv4/IPv6字面地址。修复使用Network地址解析，并按地址字节匹配显式IP例外；IPv4-mapped IPv6统一至IPv4，多个等价规则拒绝。未实现CIDR规则时，对字面地址失败关闭，检查位于HTTPS早退之前。显式代理、证书/TLS及域名规则仍优先；未修改Info.plist授权配置。

原生ATS回归先保留原判断红灯，再转绿。独立复审发现的HTTPS CIDR与等价IP拼写边界另行补红灯并修复；正反用例同时验证显式允许、显式禁止和冲突别名。生产自动恢复仍未启用；另修复下述暂停状态覆盖。

## 暂停状态覆盖回归

ATS修复后的reviewed-device-contracts运行201项：199通过、2失败、0跳过，失败是音频路由与预滚等待播放条件超时。用户确认前台后的foreground-device-contracts同制品定向复测2项：预滚通过，音频路由在16秒后出现intent=false但状态ready而非paused，保留该具体失败，未改断言或延长等待。

根因是AVPlayerItem就绪KVO回调异步投递到主队列；它可以在已确认暂停后执行，原handleItemStatus在播放器暂停且无播放意图时无条件写ready。新增真实本地MP4回归先确认初始ready、播放出帧、暂停，随后注入同一item的就绪通知并排空队列。pause-red稳定复现ready!=paused。最小修复在该分支保留已确认的paused，初次就绪仍ready；回归继续要求intent=false、rate=0、位置不动及显式play后恢复进度。没有更改自动恢复条件、音频策略或15秒看门狗。

此修复只证明暂停状态一致性，不能据此认定所有前后台暂停或penalty-box根因已解决。新增测试的手动KVO通知在Swift5构建下有Swift6异步上下文迁移警告；通知对无挂起点，当前编译/行为验证有效，完整警告保留。

## 公开接口采集与验收工具

新增--public-policy-cycle，复用120秒素材、140秒原生期限和240秒采集期限。通过YlApplePlayerHost的load、setVideoConstraints、selectVideoTrack，在8/24/50/70秒分别施加320宽上限、清除上限、固定320低档、恢复自动，保留初始自动阶段。记录实际命令成功、item变化、同一session、host状态、accepted constraints、固定档位及实际纹理新帧。

采集验证要求五阶段顺序齐全，每阶段至少3条主采样及3次新帧提交；caps/fixed只能提交320宽新帧，三个不受限阶段均须看到640宽新帧。缺阶段、错误策略、失败命令、session改变、无新帧、恢复后无高档、failed状态均拒绝；EOF继续独立要求，不以策略阶段通过替代整轮通过。Python红灯和失败关闭回归保留。

统一测试还发现既有验收条件解析器不识别!targetEnvironment(simulator)。现支持单个!作用于已知条件，保留未知条件失败关闭及现有iOS Simulator预期语义；未把它当作物理iOS专用身份推断器。镜像声明839/883仅为声明数量，实际执行另列。

## 真机结果与失败边界

设备iPhone16/iPhone17,3、iOS27.2(24B119)，沿用已授权开发签名。原冻结配置哈希4e4f256c59465f4a573d6ab1c48f7a7571294638025088d0cddba9325f5032ea；独立零延迟诊断配置哈希9f63acdf1ab0ce92c5565bc3a750478f0c6c5ba76cef88c7e1092cfcd89b01f1，均未修改。

修复前original、zero-latency及补错误码的diagnostic-original均在首请求前失败，全部保留。首次ATS修复后fixed-original五阶段策略/帧通过，但在104.368733002秒转为暂停，整轮失败；用户随后确认发生过锁屏或切换App。记录为有外部中断上下文，rootCauseProven=false，不把该样本用于声称前台缺陷或后台恢复已修。fixed-zero-latency到120.028167985秒，整轮通过。

新增临时禁用idleTimer（结束后恢复原值）作为诊断环境控制，系统前后台/音频路由事件保存signals.jsonl；它不改变恢复门槛。复审修复前的acceptance-original/zero分别到120.032635081/120.015023775秒，均通过、signals为空。最终复审候选另行重测，结果如下。

| 运行 | 整轮结果 | 末位置（秒） | 说明 |
| --- | --- | --- | --- |
| reviewed-original | 通过 | 120.027789450 | 五阶段及EOF均通过；系统事件为空 |
| reviewed-zero-latency | 失败保留 | 26.545854144 | 28.282844秒失去active，28.908871秒进入后台；测试取消 |
| foreground-zero-latency | 通过 | 120.012933014 | 五阶段及EOF均通过；系统事件为空 |
| pause-fixed-original | 通过 | 120.024520068 | 五阶段及EOF均通过；系统事件为空 |
| pause-fixed-zero-latency | 通过 | 120.030292073 | 五阶段及EOF均通过；系统事件为空 |

pause-fixed-original：initial-auto 32条主采样/183新帧/宽度[320, 640]；caps 62条主采样/372新帧/宽度[320]；clear-caps 100条主采样/599新帧/宽度[320, 640]；fixed 78条主采样/474新帧/宽度[320]；restore-auto 203条主采样/1247新帧/宽度[320, 640]。
四次用户策略切换的新帧间隔为[274.128, 604.668, 172.181, 188.978]ms，texture clear分别为[1, 1, 1, 1]；不作为自动恢复性能改善证据。

pause-fixed-zero-latency：initial-auto 32条主采样/183新帧/宽度[320, 640]；caps 62条主采样/306新帧/宽度[320]；clear-caps 100条主采样/613新帧/宽度[320, 640]；fixed 78条主采样/475新帧/宽度[320]；restore-auto 211条主采样/1298新帧/宽度[320, 640]。
四次用户策略切换的新帧间隔为[294.552, 119.33, 172.056, 172.08]ms，texture clear分别为[1, 1, 1, 1]；不作为自动恢复性能改善证据。

用户确认可保持前台后，foreground-zero-latency使用ATS修复候选的同一二进制完成补测；被后台中断的reviewed-zero-latency仍保留失败。随后暂停状态修复重新构建，最终pause-fixed两轮使用同一新制品、原网络配置和原期限完成，不能把此前候选和最终候选混称同一二进制。

媒体receipt不授予capabilityAccepted；成功矩阵的publicPolicyObservation中capabilityAccepted、physicalOutputVerified和continuityAccepted均为false。仅证明原生typed host和测试纹理接收器下的受控矩阵；未覆盖Dart messenger、旧恢复候选与公开命令竞争、凭据竞争、物理屏幕、音画或字幕连续性。新帧间隔保留实测，不宣称缩短替换空档。

## 统一验收、台账与后续

最终候选受影响矩阵：iPhone202通过、macOS177通过，均0失败/0跳过；逐一核对8个选定测试类的执行身份，不以声明数代替执行数。此前201项中的2个失败、前台2项复测的1个失败与pause-red均独立保留。网络工具118、benchmark294通过；消费者夹具46项中45通过、1因本机历史focused evidence缺失跳过。最终镜像839/883声明及历史来源检查通过。独立media-core/API模块编译、8个隐藏符号检查、11项RTMP协议回归通过。消费者夹具已在最终测试源码上重测。网络工具、benchmark和core/API检查复用暂停修复前记录；后续仅AvPlayer私有状态处理和回归用例/声明数改变，上述工具/核心实现未变，最终Apple模块由iOS/macOS矩阵重新编译。未将受影响范围冒充完整Flutter/Android/全Apple消费者验收。

首次Swift可选字段编译错误、沙箱回环权限失败、条件解析器失败、ATS所有红灯和全部真机失败均保留；构建警告原样保存。历史14组、3435个清单文件逐一校验未变。

生产源码身份由9fd66d341470a59bbc1eca827c85f52e63b81766ce7a0f361477e1abe7db8064更新为41b62a909e274818876d5b08c0999f476d0874ef131ea2a3db5bea86830441c2。台账仅更新源码绑定、本轮证据和后续动作；102行implementation/verification/acceptance状态不变，最终核对sourceMatches=true、releaseReady=false。

独立复审（public_policy_review）已确认两项ATS P1闭合，暂停状态修复定向复核无未解决P1/P2；核对202/177实际身份、21项源码绑定、原失败保留及102行状态未变。原始结论在independent-review.txt。最终媒体与台账通过独立记录核验；归档核验逐文件比较26份完整xcresult与原始bundle，549条原始来源记录通过哈希检查。归档校验脚本首次路径拼接笔误及修正记录保留，重新校验通过。发布就绪与性能阈值--require-ready仍必须返回1，不把结构检查通过当作发布门禁通过。

保留：原配置稳定安全自动恢复、公开命令与恢复候选竞争、凭据竞争、替换新帧空档、真实音频路由和前后台恢复、Dart公开链路、物理音画/字幕、多设备最低系统、DRM/Dolby授权及其他历史未验收项。旧终末停顿不恢复待办。仅保存本地提交，不合并、不推送、不打标签、不发布。
