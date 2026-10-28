from pathlib import Path
import json,hashlib,sys,subprocess
raw=Path('/private/tmp/yl-public-policy');root=Path.cwd();sha=lambda b:hashlib.sha256(b).hexdigest()
sys.path.insert(0,str(root/'tool/consumer_fixtures/apple_flutter'));import main_example_tests as gate
scope={}
classes={'YlDashResourceLoaderTests','YlAppleSessionTests','YlApplePublicationTests','YlNetworkByteSourceTests','YlLiveReconnectControllerTests','YlPlatformServicesTests','YlAvPlayerNonblockingMetadataTests','YlNetworkRequestPolicyTests'}
for mode,platform in [('device','ios'),('macos','macos')]:
 tree=json.loads((raw/(f'reviewed-{mode}-contracts-tests.json')).read_text());nodes=list(gate.case_nodes(tree['testNodes']));ids=[n['nodeIdentifier'] for n in nodes];assert len(ids)==len(set(ids))
 expected={i for i in gate.expected_identities(root/'tool/consumer_fixtures/apple_flutter',platform) if i.split('/')[0] in classes};assert set(ids)==expected,(mode,len(ids),len(expected))
 failed={n['nodeIdentifier'] for n in nodes if n['result']=='Failed'}
 counts={c:sum(i.startswith(c+'/') for i in ids) for c in classes};counts={k:v for k,v in counts.items() if v}
 value=dict(executed=len(ids),passed=sum(n['result']=='Passed' for n in nodes),failed=len(failed),skipped=sum(n['result']=='Skipped' for n in nodes),classes=counts)
 if mode=='device':
  retry=json.loads((raw/'foreground-device-contracts-tests.json').read_text());retried=list(gate.case_nodes(retry['testNodes']));assert {n['nodeIdentifier'] for n in retried}==failed and all(n['result']=='Passed' for n in retried)
  value['sameBinaryForegroundRetest']={'cases':sorted(failed),'passed':len(retried),'failed':0}
 else:assert not failed and value['skipped']==0
 scope[mode]=value
(raw/'native-scope.json').write_text(json.dumps(scope,indent=2)+'\n')
identity=json.loads((raw/'source-identity.json').read_text())
for p,h in identity.items():assert sha(Path(p).read_bytes())==h,p
names=['reviewed-original','reviewed-zero-latency','foreground-zero-latency'];receipts=[json.loads((raw/'media'/n/'receipt.json').read_text()) for n in names]
assert all(r['binaryHashes']==receipts[0]['binaryHashes'] and r['binaryIdentityUnchanged'] and r['ownedProcessExited'] for r in receipts)
assert receipts[0]['passed'] and not receipts[1]['passed'] and receipts[2]['passed']
products=Path('/private/tmp/yl-public-policy-ios/Build/Products')
for p,h in receipts[0]['binaryHashes'].items():assert sha((products/p).read_bytes())==h,p
(raw/'final-source-binding.json').write_text(json.dumps(dict(sourceFilesVerified=len(identity),sourceHashes=identity,mediaRuns=names,sameBinaryAcrossFinalMediaAndRetest=True,productsStillMatch=True,ownedProcessesExited=True),indent=2)+'\n')
media=[]
for name in names:
 p=raw/'media'/name;receipt=json.loads((p/'receipt.json').read_text());rows=[json.loads(x) for x in (p/'rows.jsonl').read_text().splitlines()];frame=receipt.get('continuityObservation',{})
 media.append(dict(name=name,passed=receipt['passed'],lastPosition=rows[-1]['position'],completed=rows[-1]['completed'],phaseObservation=receipt.get('publicPolicyObservation'),boundaries=frame.get('replacementBoundaries'),maximumPublishedFrameGapMs=frame.get('maximumPublishedFrameGapMs'),signals=[json.loads(x) for x in (p/'signals.jsonl').read_text().splitlines()]))
(raw/'final-media-analysis.json').write_text(json.dumps(media,indent=2)+'\n')
report=Path('docs/superpowers/reports/2026-10-28-ios-public-policy.md');s=report.read_text()
lines=['| 最终候选运行 | 整轮结果 | 末位置（秒） | 说明 |','| --- | --- | --- | --- |']
for m in media:
 lines.append(f"| {m['name']} | {'通过' if m['passed'] else '失败保留'} | {m['lastPosition']:.9f} | {'五阶段及EOF均通过；系统事件为空' if m['passed'] else '28.282844秒失去active，28.908871秒进入后台；测试取消'} |")
for m in [media[0],media[2]]:
 phases=m['phaseObservation']['phases'];lines.append('\n'+m['name']+'：'+ '；'.join(f"{p['phase']} {p['rows']}条主采样/{p['publishedFrames']}新帧/宽度{p['widths']}" for p in phases)+'。')
 gaps=[round(b['publicationGapMs'],3) for b in m['boundaries']];lines.append(f"四次用户策略切换的新帧间隔为{gaps}ms，texture clear分别为{[b['textureClears'] for b in m['boundaries']]}；不作为自动恢复性能改善证据。")
lines.append('\n用户已明确确认可保持前台后，foreground-zero-latency沿用同一二进制、该轮既定网络配置及原期限完成补测；被后台中断的reviewed-zero-latency仍保留失败，不改写结果。')
s=s.replace('FINAL_MEDIA_PENDING','\n'.join(lines))
assert scope['device']['executed']==201 and scope['macos']['executed']==176
s=s.replace('FINAL_TESTS_PENDING','iPhone受影响矩阵201项：首轮199通过、2项等待原生播放条件超时，0跳过；用户明确前台条件后，同制品、原5秒等待与原准备期限定向复测这2项均通过。原失败方法为testAudioRouteLossPausesIntentWithoutNetworkTimeoutAndRequiresExplicitResume和testPrerollCandidateCreatesFreshItemAndCancelsAfterRealReadiness，保留首轮失败，不伪装为单次全绿。macOS扩大矩阵176通过，0失败/0跳过。网络工具118、benchmark294通过；消费者夹具46项中45通过、1因本机历史focused evidence缺失跳过。镜像/历史来源检查通过。独立media-core/API模块编译、8个隐藏符号检查、11项RTMP协议回归通过。未将此受影响范围冒充完整Flutter/Android/全Apple消费者验收。')
report.write_text(s)
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());d['evidence']['ios-public-policy-20261028']['sha256']=sha(report.read_bytes());p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(scope));print('Final media source/binary binding verified')
