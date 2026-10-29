from pathlib import Path
import json,hashlib,sys
raw=Path('/private/tmp/yl-credential-race');sha=lambda b:hashlib.sha256(b).hexdigest()
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');import main_example_tests as gate
classes={'YlDashResourceLoaderTests','YlAppleSessionTests','YlApplePublicationTests','YlNetworkByteSourceTests','YlLiveReconnectControllerTests','YlPlatformServicesTests','YlAvPlayerNonblockingMetadataTests','YlNetworkRequestPolicyTests'};scope={}
for mode,platform,count in [('macos','macos',185),('device','ios',210)]:
 p=raw/('fenced-'+mode+'-contracts-tests.json')
 if not p.exists():continue
 nodes=list(gate.case_nodes(json.loads(p.read_text())['testNodes']));ids=[n['nodeIdentifier'] for n in nodes]
 expected={i for i in gate.expected_identities(Path('tool/consumer_fixtures/apple_flutter'),platform) if i.split('/')[0] in classes}
 assert len(ids)==len(set(ids))==count and set(ids)==expected and all(n['result']=='Passed' for n in nodes)
 scope[mode]=dict(passed=count,failed=0,skipped=0,classes={c:sum(i.startswith(c+'/') for i in ids) for c in sorted(classes) if any(i.startswith(c+'/') for i in ids)})
(raw/'final-native-scope.json').write_text(json.dumps(scope,indent=2)+'\n')
identity=json.loads((raw/'source-identity.json').read_text())
for p,h in identity.items():assert sha(Path(p).read_bytes())==h,p
(raw/'final-source-binding.json').write_text(json.dumps(dict(sourceFilesVerified=len(identity),sourceHashes=identity,scope=scope,mediaRetested=False),indent=2)+'\n')
report=Path('docs/superpowers/reports/2026-10-28-ios-credential-race.md');s=report.read_text()
if 'device' in scope:
 s=s.replace('FINAL_TESTS_PENDING','最终同源码候选：macOS185/185、iPhone210/210，均0失败/0跳过；核对8个选定类的唯一执行身份。复审前macOS183/183和iOS编译结果单独保存，不冒充最终制品。凭据/提交锁定向5/5通过。网络工具124通过，消费者夹具46项中45通过、1历史focused evidence缺失跳过；镜像声明iOS847/macOS891及历史来源检查通过。iPhone起初断开，用户重新连接并解锁后运行上述最终原生矩阵。设备原生测试中有本地媒体与受控网络合约，不等同长素材ABR或物理连续性验收。')
report.write_text(s)
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());d['evidence']['ios-credential-race-20261028']['sha256']=sha(report.read_bytes());p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
print(scope)
