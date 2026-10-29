from pathlib import Path
import json,hashlib,subprocess,sys
raw=Path('/private/tmp/yl-public-race');root=Path.cwd();sha=lambda b:hashlib.sha256(b).hexdigest()
sys.path.insert(0,str(root/'tool/consumer_fixtures/apple_flutter'));import main_example_tests as gate
classes={'YlDashResourceLoaderTests','YlAppleSessionTests','YlApplePublicationTests','YlNetworkByteSourceTests','YlLiveReconnectControllerTests','YlPlatformServicesTests','YlAvPlayerNonblockingMetadataTests','YlNetworkRequestPolicyTests'};scope={}
for mode,platform,count in [('device','ios',203),('macos','macos',178)]:
 name='deadline-fixed-'+mode;tree=json.loads((raw/(name+'-contracts-tests.json')).read_text());nodes=list(gate.case_nodes(tree['testNodes']));ids=[n['nodeIdentifier'] for n in nodes]
 expected={i for i in gate.expected_identities(root/'tool/consumer_fixtures/apple_flutter',platform) if i.split('/')[0] in classes}
 assert len(ids)==len(set(ids))==count and set(ids)==expected and all(n['result']=='Passed' for n in nodes)
 scope[mode]=dict(passed=count,failed=0,skipped=0,classes={c:sum(i.startswith(c+'/') for i in ids) for c in sorted(classes) if any(i.startswith(c+'/') for i in ids)})
(raw/'final-native-scope.json').write_text(json.dumps(scope,indent=2)+'\n')
identity=json.loads((raw/'source-identity.json').read_text())
for p,h in identity.items():assert sha(Path(p).read_bytes())==h,p
names=['deadline-fixed-caps','deadline-fixed-fixed'];rs=[json.loads((raw/'media'/n/'receipt.json').read_text()) for n in names]
assert all(r['passed'] and r['binaryIdentityUnchanged'] and r['ownedProcessExited'] and r['binaryHashes']==rs[0]['binaryHashes'] for r in rs)
products=Path('/private/tmp/yl-public-policy-ios/Build/Products')
for p,h in rs[0]['binaryHashes'].items():assert sha((products/p).read_bytes())==h,p
(raw/'final-source-binding.json').write_text(json.dumps(dict(sourceFilesVerified=len(identity),sourceHashes=identity,mediaRuns=names,sameBinary=True,productsStillMatch=True,ownedProcessesExited=True),indent=2)+'\n')
media=[]
for n in names:
 p=raw/'media'/n;r=json.loads((p/'receipt.json').read_text());rows=[json.loads(x) for x in (p/'rows.jsonl').read_text().splitlines()];signals=[json.loads(x) for x in (p/'signals.jsonl').read_text().splitlines()];assert not signals
 e=rows[-1]['automaticEvents'][0];obs=r['publicRaceObservation'];cont=r['continuityObservation'];assert obs['oldCandidateRejected'] and obs['sourceAttempts']==1
 media.append(dict(name=n,passed=r['passed'],position=rows[-1]['position'],completed=rows[-1]['completed'],race=obs,policy=r['policyObservation'],event=e,signals=signals,boundaries=cont['replacementBoundaries']))
(raw/'final-media-analysis.json').write_text(json.dumps(media,indent=2)+'\n')
lines=['用户再次确认连续前台后，期限修复后的同一制品完成以下两轮。系统前后台/音频事件均为空，原配置被中断的失败仍独立保留。','', '| 最终运行 | 结果 / 片尾位置（秒） | 源预算 | 策略后主采样 / 新帧 |', '| --- | --- | --- | --- |']
for m in media:
 o=m['race'];lines.append(f"| {m['name']} | 通过 / {m['position']:.9f} | {o['sourceAttempts']} | {o['policyRows']} / {o['publishedFrames']} |")
for m in media:
 e=m['event'];lines.append(f"\n{m['name']}：票据due={e['due']:.6f}，准备期限={e['warmupDeadlineElapsed']:.6f}，公开命令完成={e['publicCommandCompletedElapsed']:.6f}，候选清理完成={e['warmupCompletedElapsed']:.6f}秒。公开命令成功、同session换item、未手动作废票据；候选cancelled/detached，不安装新候选，后续新帧只提交320宽。")
 gaps=[round(b['publicationGapMs'],3) for b in m['boundaries']];clears=[b['textureClears'] for b in m['boundaries']];lines.append(f"用户策略切换新帧间隔{gaps}ms，texture clear={clears}；不作为自动恢复空档改善证据。")
report=Path('docs/superpowers/reports/2026-10-28-ios-public-race.md');s=report.read_text().replace('FINAL_DEVICE_MEDIA_PENDING','\n'.join(lines)).replace('FINAL_TESTS_PENDING','最终期限修复候选：iPhone203/203、macOS178/178，均0失败/0跳过；核对8个选定类的唯一执行身份。复审前203/178结果另存，不混同源码版本。网络工具120通过，accesslog定向31通过；消费者夹具46项中45通过、1历史focused evidence缺失跳过。镜像声明iOS840/macOS884与固定历史来源检查通过，声明数不替代执行数。生产、依赖与benchmark工具未变，复用基线已有294项benchmark及core/API证据；未冒充全Flutter/Android/全部Apple消费者验收。').replace('最终真机待验收（完成后据实更新）、','')
report.write_text(s)
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());d['evidence']['ios-public-race-20261028']['sha256']=sha(report.read_bytes())
for r in d['rows']:
 if r['platform']=='ios' and r['requirement']=='CAP-ABR':r['nextAction']='qualify-public-pause-seek-credential-races-original-auto-recovery-frame-gap-and-physical-output'
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
print(scope);print('Final source, binary and media evidence matched')
