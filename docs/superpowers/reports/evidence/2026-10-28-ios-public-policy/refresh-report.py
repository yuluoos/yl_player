from pathlib import Path
import hashlib,json,subprocess,sys
raw=Path('/private/tmp/yl-public-policy');root=Path.cwd();sha=lambda b:hashlib.sha256(b).hexdigest()
sys.path.insert(0,str(root/'tool/release_readiness'));import check
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());before=json.loads(subprocess.check_output(['git','show','HEAD:tool/release_readiness/inventory.json'],text=True));snapshot=check.source_snapshot(root)
changes=[p for p,h in before['source']['files'].items() if snapshot['files'].get(p)!=h]
expected=['packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift','packages/yl_player_media_core/darwin/yl_player_media_core/Sources/yl_player_media_core/Network/YlManagedHTTPTransport.swift'];assert sorted(changes)==sorted(expected)
(raw/'source-comparison.json').write_text(json.dumps(dict(baseline='7c4cf933',beforeHash=before['source']['sha256'],afterHash=snapshot['sha256'],changedProductionFiles=changes),indent=2)+'\n')
report=Path('docs/superpowers/reports/2026-10-28-ios-public-policy.md');s=report.read_text().replace('生产改动仅为上述网络策略文件，生产自动恢复仍未启用。','生产自动恢复仍未启用；另修复下述暂停状态覆盖。').replace('镜像声明838/882','镜像声明839/883').replace('d8a964740c8cee0e5f4dff94259283cea34c573d87ca7425d7a5c5cc4308d856',snapshot['sha256'])
s=s.replace('## 公开接口采集与验收工具','''## 暂停状态覆盖回归

ATS修复后的reviewed-device-contracts运行201项：199通过、2失败、0跳过，失败是音频路由与预滚等待播放条件超时。用户确认前台后的foreground-device-contracts同制品定向复测2项：预滚通过，音频路由在16秒后出现intent=false但状态ready而非paused，保留该具体失败，未改断言或延长等待。

根因是AVPlayerItem就绪KVO回调异步投递到主队列；它可以在已确认暂停后执行，原handleItemStatus在播放器暂停且无播放意图时无条件写ready。新增真实本地MP4回归先确认初始ready、播放出帧、暂停，随后注入同一item的就绪通知并排空队列。pause-red稳定复现ready!=paused。最小修复在该分支保留已确认的paused，初次就绪仍ready；回归继续要求intent=false、rate=0、位置不动及显式play后恢复进度。没有更改自动恢复条件、音频策略或15秒看门狗。

此修复只证明暂停状态一致性，不能据此认定所有前后台暂停或penalty-box根因已解决。新增测试的手动KVO通知在Swift5构建下有Swift6异步上下文迁移警告；通知对无挂起点，当前编译/行为验证有效，完整警告保留。

## 公开接口采集与验收工具''')
report.write_text(s);d['source']=snapshot;d['evidence']['ios-public-policy-20261028']['sha256']=sha(report.read_bytes())
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
p=Path('docs/superpowers/plans/2026-10-28-ios-public-policy.md');s=p.read_text();s+='\n最终回归补充：原生路由暂停16秒后被延迟item-ready回调覆盖为ready。真实媒体+KVO顺序回归先红，保留已确认paused的最小修复后验证初始ready/暂停不动/显式续播；最终扩大到共享AvPlayer受影响矩阵和两轮同制品真机媒体。\n';p.write_text(s)
# Update archive verification to cover exactly the two confirmed production fixes.
p=raw/'verify-archive.py';s=p.read_text();s=s.replace("assert changes==['packages/yl_player_media_core/darwin/yl_player_media_core/Sources/yl_player_media_core/Network/YlManagedHTTPTransport.swift']",'assert sorted(changes)==sorted('+repr(expected)+')');p.write_text(s)
p=raw/'archive.py';s=p.read_text().replace("if not path.is_file() or any(p.suffix=='.xcresult' for p in path.parents):continue","if not path.is_file() or '__pycache__' in path.parts or path.suffix == '.pyc' or any(p.suffix=='.xcresult' for p in path.parents):continue");p.write_text(s)
print(snapshot['sha256'])
