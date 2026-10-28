from pathlib import Path
import json,hashlib,sys,subprocess
root=Path.cwd();raw=Path('/private/tmp/yl-public-policy')
sys.path.insert(0,str(root/'tool/release_readiness'));import check
inventory=Path('tool/release_readiness/inventory.json');d=json.loads(inventory.read_text());before=json.loads(subprocess.check_output(['git','show','HEAD:tool/release_readiness/inventory.json'],text=True));snapshot=check.source_snapshot(root)
changed=[p for p,h in before['source']['files'].items() if snapshot['files'].get(p)!=h]
assert changed==['packages/yl_player_media_core/darwin/yl_player_media_core/Sources/yl_player_media_core/Network/YlManagedHTTPTransport.swift']
(raw/'source-comparison.json').write_text(json.dumps(dict(baseline='7c4cf933',beforeHash=before['source']['sha256'],afterHash=snapshot['sha256'],changedProductionFiles=changed),indent=2)+'\n')
report=Path('docs/superpowers/reports/2026-10-28-ios-public-policy.md')
report.write_text(f'''# iOS 公开接口清晰度矩阵与本地地址访问修复

基线 `7c4cf933`，分支 `codex/abr-recovery`。继续已授权未完成项，沿用系统排障、测试驱动和集中验收。[原始证据](evidence/2026-10-28-ios-public-policy/)保留全部失败及完整xcresult。未发布。

## 确认的问题与修复

原生typed public host首次加载自有LAN DASH素材在首个请求前返回policy.unsupported，服务器请求为0。定位到prepareDash使用managed HTTP预检，而YlManagedTransportRestrictions只把loopback、无点名称和.local认作NSAllowsLocalNetworking允许的目标，误拒绝192.168.1.20。这是公开接口的首请求前阻断，不是对旧后端penalty-box行为的原因判定。

[Apple官方NSAllowsLocalNetworking文档](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)说明该配置覆盖IPv4/IPv6字面地址。修复使用Network地址解析，并按地址字节匹配显式IP例外；IPv4-mapped IPv6统一至IPv4，多个等价规则拒绝。未实现CIDR规则时，对字面地址失败关闭，检查位于HTTPS早退之前。显式代理、证书/TLS及域名规则仍优先；未修改Info.plist授权配置。

原生ATS回归先保留原判断红灯，再转绿。独立复审发现的HTTPS CIDR与等价IP拼写边界另行补红灯并修复；正反用例同时验证显式允许、显式禁止和冲突别名。生产改动仅为上述网络策略文件，生产自动恢复仍未启用。

## 公开接口采集与验收工具

新增--public-policy-cycle，复用120秒素材、140秒原生期限和240秒采集期限。通过YlApplePlayerHost的load、setVideoConstraints、selectVideoTrack，在8/24/50/70秒分别施加320宽上限、清除上限、固定320低档、恢复自动，保留初始自动阶段。记录实际命令成功、item变化、同一session、host状态、accepted constraints、固定档位及实际纹理新帧。

采集验证要求五阶段顺序齐全，每阶段至少3条主采样及3次新帧提交；caps/fixed只能提交320宽新帧，三个不受限阶段均须看到640宽新帧。缺阶段、错误策略、失败命令、session改变、无新帧、恢复后无高档、failed状态均拒绝；EOF继续独立要求，不以策略阶段通过替代整轮通过。Python红灯和失败关闭回归保留。

统一测试还发现既有验收条件解析器不识别!targetEnvironment(simulator)。现支持单个!作用于已知条件，保留未知条件失败关闭及现有iOS Simulator预期语义；未把它当作物理iOS专用身份推断器。镜像声明838/882仅为声明数量，实际执行另列。

## 真机结果与失败边界

设备iPhone16/iPhone17,3、iOS27.2(24B119)，沿用已授权开发签名。原冻结配置哈希4e4f256c59465f4a573d6ab1c48f7a7571294638025088d0cddba9325f5032ea；独立零延迟诊断配置哈希9f63acdf1ab0ce92c5565bc3a750478f0c6c5ba76cef88c7e1092cfcd89b01f1，均未修改。

修复前original、zero-latency及补错误码的diagnostic-original均在首请求前失败，全部保留。首次ATS修复后fixed-original五阶段策略/帧通过，但在104.368733002秒转为暂停，整轮失败；用户随后确认发生过锁屏或切换App。记录为有外部中断上下文，rootCauseProven=false，不把该样本用于声称前台缺陷或后台恢复已修。fixed-zero-latency到120.028167985秒，整轮通过。

新增临时禁用idleTimer（结束后恢复原值）作为诊断环境控制，系统前后台/音频路由事件保存signals.jsonl；它不改变恢复门槛。复审修复前的acceptance-original/zero分别到120.032635081/120.015023775秒，均通过、signals为空。最终复审候选另行重测，结果如下。

FINAL_MEDIA_PENDING

所有媒体receipt仍保持capabilityAccepted、physicalOutputVerified和continuityAccepted为false。仅证明原生typed host和测试纹理接收器下的受控矩阵；未覆盖Dart messenger、旧恢复候选与公开命令竞争、凭据竞争、物理屏幕、音画或字幕连续性。新帧间隔保留实测，不宣称缩短替换空档。

## 统一验收、台账与后续

FINAL_TESTS_PENDING

首次Swift可选字段编译错误、沙箱回环权限失败、条件解析器失败、ATS所有红灯和全部真机失败均保留；构建警告原样保存。历史14组、3435个清单文件逐一校验未变。

生产源码身份由{before['source']['sha256']}更新为{snapshot['sha256']}。台账仅更新源码绑定、本轮证据和后续动作；102行implementation/verification/acceptance状态不变，releaseReady仍须为false。

REVIEW_PENDING

保留：原配置稳定安全自动恢复、公开命令与恢复候选竞争、凭据竞争、替换新帧空档、真实音频路由和前后台恢复、Dart公开链路、物理音画/字幕、多设备最低系统、DRM/Dolby授权及其他历史未验收项。旧终末停顿不恢复待办。仅保存本地提交，不合并、不推送、不打标签、不发布。
''')
d['source']=snapshot;key='ios-public-policy-20261028';d['evidence'][key]=dict(path=str(report),sha256=hashlib.sha256(report.read_bytes()).hexdigest(),kind='report')
for r in d['rows']:
 if r['platform'] in ['ios','macos'] and r['requirement'] in ['CAP-ABR','CAP-DASH','REG-NET']:
  if key not in r['evidence']:r['evidence'].append(key)
 if r['platform']=='ios' and r['requirement']=='CAP-ABR':r['nextAction']='qualify-original-auto-recovery-public-command-credential-races-frame-gap-and-physical-output'
for a,b in zip(before['rows'],d['rows']):
 for k in ['requirement','platform','implementation','verification','acceptance']:assert a[k]==b[k]
inventory.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
print('Draft report and source-bound ledger saved',snapshot['sha256'])
