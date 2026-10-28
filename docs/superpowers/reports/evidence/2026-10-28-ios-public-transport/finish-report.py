from pathlib import Path
import hashlib,json
raw=Path('/private/tmp/yl-public-transport');report=Path('docs/superpowers/reports/2026-10-28-ios-public-transport.md');s=report.read_text()
s=s.replace('FINAL_TESTS_PENDING','最终同源码候选：iPhone205/205、macOS180/180，均0失败/0跳过；逐一核对8个选定类的唯一测试身份。网络工具122通过（含46项ABR定向验证器），消费者夹具46项中45通过、1历史focused evidence缺失跳过；镜像声明iOS842/macOS886及固定历史来源检查通过。声明数量不作为全部Apple消费者执行证据。台账15项回归通过，结构门禁通过，发布与性能require-ready均按预期返回1。复用未受影响的基线core/API、benchmark证据，未声称本轮执行全部Flutter/Android/Apple测试。编译及XCTest最低部署版本等原有警告保留在原始构建日志。')
media=json.loads((raw/'final-media-analysis.json').read_text());final=[m for m in media if m['phase']=='review-media']
if len(final)==2:
 lines=['复审修复后的同一制品两轮完整前台采集如下（系统前后台/音频事件均为空）：','','| 场景 | 整轮结果 | EOF位置（秒） | 预算 | 命令后帧宽 | 实际帧PTS数量 |','| --- | --- | --- | --- | --- | --- |']
 for m in final:lines.append(f"| {m['name']} | {'通过' if m['passed'] else '失败'} | {m['position']:.9f} | {m['attempts']} | {m['postCommandWidths']} | {m['ptsCount']} |")
 for m in final:
  e=m['event'];lines.append(f"\n{m['name']}：命令版本{e['publicCommandIntentBefore']}→{e['publicCommandIntentAfter']}，票据版本{e['ticketIntentRevision']}；命令完成{e['publicCommandCompletedElapsed']:.6f}秒，候选清理{e['warmupCompletedElapsed']:.6f}秒，原期限{e['warmupDeadlineElapsed']:.6f}秒。旧候选cancelled/detached，同session/item保留，第二张票据仍计入最多2次源预算，未安装。")
  if m['name']=='pause':
   r=m['resume'];lines.append(f"暂停后显式play完成{r['completedElapsed']:.6f}秒，oldTicketAuthorized=false；之后{m['postCommandFrames']}帧均有真实PTS。")
  else:lines.append(f"公开seek目标{m['seekTarget']:.3f}秒，随后实际发布帧最小PTS={m['ptsMinimum']:.6f}秒；缺失/无效/早于目标50ms容差的帧行数={m['invalidPTSRows']}。这是实际缓冲区PTS观察，仍不是物理屏幕展示或音画同步证明。")
  lines.append('整轮仍在要求恢复640宽的新帧门槛失败；保留原始passed=false，不降为仅EOF或低档连续播放即通过。')
 lines.append('\n完整升档恢复、自动替换播放连续性与物理输出仍未验收。本轮未实际安装恢复候选，不能证明或宣称缩短替换新帧空档。')
 s=s.replace('FINAL_MEDIA_PENDING','\n'.join(lines))
report.write_text(s)
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());d['evidence']['ios-public-transport-20261028']['sha256']=hashlib.sha256(report.read_bytes()).hexdigest();p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
