from pathlib import Path
import json,hashlib,sys,subprocess
raw=Path('/private/tmp/yl-public-policy');root=Path.cwd();sha=lambda b:hashlib.sha256(b).hexdigest()
sys.path.insert(0,str(root/'tool/consumer_fixtures/apple_flutter'));import main_example_tests as gate
scope={};classes={'YlDashResourceLoaderTests','YlAppleSessionTests','YlApplePublicationTests','YlNetworkByteSourceTests','YlLiveReconnectControllerTests','YlPlatformServicesTests','YlAvPlayerNonblockingMetadataTests','YlNetworkRequestPolicyTests'}
for mode,platform,expected_count in [('device','ios',202),('macos','macos',177)]:
 tree=json.loads((raw/(f'pause-fixed-{mode}-contracts-tests.json')).read_text());nodes=list(gate.case_nodes(tree['testNodes']));ids=[n['nodeIdentifier'] for n in nodes];assert len(ids)==len(set(ids))==expected_count
 expected={i for i in gate.expected_identities(root/'tool/consumer_fixtures/apple_flutter',platform) if i.split('/')[0] in classes};assert set(ids)==expected,(mode,len(ids),len(expected))
 assert all(n['result']=='Passed' for n in nodes)
 scope[mode]=dict(executed=len(ids),passed=len(ids),failed=0,skipped=0,classes={c:sum(i.startswith(c+'/') for i in ids) for c in sorted(classes) if any(i.startswith(c+'/') for i in ids)})
(raw/'native-scope.json').write_text(json.dumps(scope,indent=2)+'\n')
identity=json.loads((raw/'source-identity.json').read_text())
for p,h in identity.items():assert sha(Path(p).read_bytes())==h,p
names=['pause-fixed-original','pause-fixed-zero-latency'];receipts=[json.loads((raw/'media'/n/'receipt.json').read_text()) for n in names]
assert all(r['binaryHashes']==receipts[0]['binaryHashes'] and r['binaryIdentityUnchanged'] and r['ownedProcessExited'] and r['passed'] for r in receipts)
products=Path('/private/tmp/yl-public-policy-ios/Build/Products')
for p,h in receipts[0]['binaryHashes'].items():assert sha((products/p).read_bytes())==h,p
(raw/'final-source-binding.json').write_text(json.dumps(dict(sourceFilesVerified=len(identity),sourceHashes=identity,mediaRuns=names,sameBinaryAcrossFinalMedia=True,productsStillMatch=True,ownedProcessesExited=True),indent=2)+'\n')
media=[]
for name in ['reviewed-original','reviewed-zero-latency','foreground-zero-latency']+names:
 p=raw/'media'/name;receipt=json.loads((p/'receipt.json').read_text());rows=[json.loads(x) for x in (p/'rows.jsonl').read_text().splitlines()];frame=receipt.get('continuityObservation',{})
 media.append(dict(name=name,passed=receipt['passed'],lastPosition=rows[-1]['position'],completed=rows[-1]['completed'],phaseObservation=receipt.get('publicPolicyObservation'),boundaries=frame.get('replacementBoundaries'),maximumPublishedFrameGapMs=frame.get('maximumPublishedFrameGapMs'),signals=[json.loads(x) for x in (p/'signals.jsonl').read_text().splitlines()]))
(raw/'final-media-analysis.json').write_text(json.dumps(media,indent=2)+'\n')
report=Path('docs/superpowers/reports/2026-10-28-ios-public-policy.md');s=report.read_text()
lines=['| 运行 | 整轮结果 | 末位置（秒） | 说明 |','| --- | --- | --- | --- |']
for m in media:lines.append(f"| {m['name']} | {'通过' if m['passed'] else '失败保留'} | {m['lastPosition']:.9f} | {'五阶段及EOF均通过；系统事件为空' if m['passed'] else '28.282844秒失去active，28.908871秒进入后台；测试取消'} |")
for m in media[-2:]:
 assert m['passed'] and not m['signals']
 phases=m['phaseObservation']['phases'];lines.append('\n'+m['name']+'：'+ '；'.join(f"{p['phase']} {p['rows']}条主采样/{p['publishedFrames']}新帧/宽度{p['widths']}" for p in phases)+'。')
 gaps=[round(b['publicationGapMs'],3) for b in m['boundaries']];lines.append(f"四次用户策略切换的新帧间隔为{gaps}ms，texture clear分别为{[b['textureClears'] for b in m['boundaries']]}；不作为自动恢复性能改善证据。")
lines.append('\n用户确认可保持前台后，foreground-zero-latency使用ATS修复候选的同一二进制完成补测；被后台中断的reviewed-zero-latency仍保留失败。随后暂停状态修复重新构建，最终pause-fixed两轮使用同一新制品、原网络配置和原期限完成，不能把此前候选和最终候选混称同一二进制。')
s=s.replace('FINAL_MEDIA_PENDING','\n'.join(lines))
s=s.replace('FINAL_TESTS_PENDING','最终候选受影响矩阵：iPhone202通过、macOS177通过，均0失败/0跳过；逐一核对8个选定测试类的执行身份，不以声明数代替执行数。此前201项中的2个失败、前台2项复测的1个失败与pause-red均独立保留。网络工具118、benchmark294通过；消费者夹具46项中45通过、1因本机历史focused evidence缺失跳过。最终镜像839/883声明及历史来源检查通过。独立media-core/API模块编译、8个隐藏符号检查、11项RTMP协议回归通过。消费者夹具已在最终测试源码上重测。网络工具、benchmark和core/API检查复用暂停修复前记录；后续仅AvPlayer私有状态处理和回归用例/声明数改变，上述工具/核心实现未变，最终Apple模块由iOS/macOS矩阵重新编译。未将受影响范围冒充完整Flutter/Android/全Apple消费者验收。')
s=s.replace('所有媒体receipt仍保持capabilityAccepted、physicalOutputVerified和continuityAccepted为false。','媒体receipt不授予capabilityAccepted；成功矩阵的publicPolicyObservation中capabilityAccepted、physicalOutputVerified和continuityAccepted均为false。')
report.write_text(s)
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());d['evidence']['ios-public-policy-20261028']['sha256']=sha(report.read_bytes());p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(scope));print('Final media source/binary binding verified')
