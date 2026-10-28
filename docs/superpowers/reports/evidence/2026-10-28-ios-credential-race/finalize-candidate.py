from pathlib import Path
import shutil
r=Path('/private/tmp/yl-credential-race')
shutil.move(r/'source-final',r/'source-before-fence');shutil.move(r/'source-identity.json',r/'source-before-fence-identity.json')
s=(r/'run-final.py').read_text().replace("name='ios-build'","name='fenced-ios-build'").replace("name=mode+'-contracts'","name='fenced-'+mode+'-contracts'");(r/'run-fenced.py').write_text(s)
p=Path('docs/superpowers/plans/2026-10-28-ios-credential-race.md');s=p.read_text().replace('生产仅增加凭据上下文只读版本','生产上下文增加只读版本与短同步提交锁，恢复策略仍只在诊断夹具');s+='\n复审P2：最后版本读取与实际安装之间存在TOCTOU。已增加并发红灯，使用与strip同锁的同步提交闭包；只包裹已完成预检的诊断DASH换item，不做网络等待/上下文重入。新增真实backend安装竞争检查；本地网络撤权测试直接discard候选loader并检查所有权已撤销。此实现选择为本轮复审修复，不改变生产恢复入口或原门槛。\n';p.write_text(s)
