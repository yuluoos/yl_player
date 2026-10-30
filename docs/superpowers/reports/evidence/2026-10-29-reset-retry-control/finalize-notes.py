from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-reset-retry-control')
p=r/'report.py';s=p.read_text().replace('EOF位置/宽度','末次位置/宽度/完成').replace("{d['final']['width']} |", "{d['final']['width']}/{d['final']['completed']} |")
s=s.replace('原生退出0、到EOF或最终高档均不能单独替代包含预算场景的严格结果。','四轮原生退出0，一轮退出65；到EOF或最终高档均不能单独替代包含预算场景的严格结果。')
s=s.replace('## 原因边界、历史及未完成项','''## 补测失败的进一步定位

budget-late-throttle原生退出65，最后位置51.099435秒、width=0、completed=false；第2次预约在54.094666秒安装后，代际1没有发布任何新帧。末次发布54.083785秒至观测结束99.420221秒持续45.336436秒无新帧，不能用此前2.080秒的最大已发布帧间隔或空replacementBoundaries掩盖。原生断言记录AVPlayerItemStatus.failed，生产恢复/播放/预算/关联全部失败。

导出的StandardOutputAndStandardError.txt显示到夹具上游192.168.50.196:56959的连接建立失败1:60、URLSession -1001、HTTP load 0/0 bytes；随后的map访问日志报告No response for map in 1s。51条代理任务没有服务器关联，其Foundation事务请求/响应字节计数均0。服务器177个已接纳连接均有已解析请求且handlerEnded，没有未记录请求；末次服务器请求在profile 51.956秒结束，早于计划70秒的第二降速。该证据支持这轮存在上游连接超时，区别于回环POSIX54；仍不能判定Wi-Fi/主机/服务器接纳路径的具体内部失效点，也不能以0计数证明未发包。没有抓包或连接探针交叉验证，不把它归因于70–75秒带宽控制、预算策略或此前回环错误。

此次xcresult的console log接口返回No console log available，原失败保留；改用export diagnostics成功取得原生标准输出。该当前失败作为替换后上游连接超时及无新帧证据保留，不复活此前已删除的旧终末停顿待办。

budget-late-mild最后安装实际晚至93.834320秒，首高档95.523501秒；70–75秒阶段没有高档请求，末次安装后无再次低档。后移10秒仍未建立目标预算场景，不能将此轮最终640称作预算耗尽后的再次恢复。后续需要先确保有效高档基线，再设计单变量故障对照；不能继续仅用固定延时假定场景已成立。

## 原因边界、历史及未完成项''')
s=s.replace("row['nextAction']='establish-repeatable-post-reset-natural-retry-control-with-unchanged-budget'", "row['nextAction']='establish-repeatable-high-baseline-before-second-fault; isolate-upstream-connect-timeout-and-natural-double-transaction; retain-budget-and-continuity-gaps'")
p.write_text(s)
p=r/'verify.py';s=p.read_text().replace("summary['totalTestCount']==summary['passedTests']==1 and summary['failedTests']==summary['skippedTests']==0", "summary['totalTestCount']==1 and summary['skippedTests']==0 and summary['passedTests']==(0 if d['nativeExitCode'] else 1) and summary['failedTests']==(1 if d['nativeExitCode'] else 0)")
s=s.replace("assert receipt['passed']==d['receiptPassed']", "assert receipt['exitCode']==d['nativeExitCode'];assert receipt['passed']==d['receiptPassed']")
p.write_text(s)
raw={str(p.relative_to(r/'media')):hashlib.sha256(p.read_bytes()).hexdigest() for n in ['budget-throttle','budget-mild','normal','budget-late-throttle','budget-late-mild'] for p in (r/'media'/n).iterdir() if p.suffix in ['.json','.jsonl']}
(r/'media-raw-identity.json').write_text(json.dumps(raw,indent=2)+'\n')
(r/'diagnostics-extraction.json').write_text(json.dumps(dict(consoleLog=dict(exitCode=1,available=False,message='No console log available',output='late-throttle-console.json'),diagnosticsExport=dict(exitCode=0,directory='late-throttle-diagnostics',log='diagnostics-export.log'),interpretation='The failed console extraction is retained. Exported native stdout contains upstream connect 1:60 and URLSession -1001 failures; underlying network path root cause unresolved.'),indent=2)+'\n')
p=Path('docs/superpowers/plans/2026-10-29-reset-retry-control.md');s=p.read_text().replace('- [ ] 从归档','- [x] 从归档').replace('- [ ] 新制品','- [x] 新制品').replace('- [ ] 关联每次','- [x] 关联每次')
s+='\n执行结果：五轮均严格失败，含四轮预算场景未成立（其中一轮另有上游连接超时、替换后45.336秒无新帧和原生失败），正常恢复轮因自然双事务缺响应日期失败。当前只确认分析口径及注释修正；不声称播放器恢复已修复或验收通过。\n'
p.write_text(s)
print('raw identities',len(raw))
