from pathlib import Path
Path('tool/playback_network/server_timing.py').write_text('''"""Bounded same-clock server durations; nested sleep is not additive to hold."""
from contextlib import contextmanager
import math

STAGES = ('latency', 'queue', 'hold', 'sleep', 'headerWrite', 'bodyWrite')


class RequestTiming:
    def __init__(self, now):
        self.now = now
        self.started = now()
        self.values = dict(version=1, valid=True, sleepRequestedSeconds=0.0)
        for stage in STAGES:
            self.values.update({stage+'Seconds':0.0, stage+'Calls':0, stage+'Failures':0})

    def add(self, field, value):
        current = self.values.get(field, 0.0)
        if not math.isfinite(value) or value < 0 or current is None:
            self.values['valid'] = False
            self.values[field] = None
        else:
            self.values[field] = current + value

    def requested_sleep(self, seconds):
        self.add('sleepRequestedSeconds', seconds)

    @contextmanager
    def measure(self, stage):
        if stage not in STAGES: raise ValueError('unknown timing stage')
        start = self.now()
        self.values[stage+'Calls'] += 1
        try:
            yield
        except BaseException:
            self.values[stage+'Failures'] += 1
            raise
        finally:
            self.add(stage+'Seconds', self.now()-start)

    def finish(self):
        seconds = self.now()-self.started
        valid = self.values['valid'] and math.isfinite(seconds) and seconds >= 0
        return dict(self.values, valid=valid, totalSeconds=seconds if valid else None)


def summarize_server_timing(rows):
    def require(ok):
        if not ok: raise ValueError('invalid server timing evidence')
    def finite(v): return type(v) in (int,float) and math.isfinite(v) and v >= 0
    fields={'version','valid','totalSeconds','sleepRequestedSeconds'} | {s+k for s in STAGES for k in ('Seconds','Calls','Failures')}
    require(isinstance(rows,list) and 0 < len(rows) <= 10000)
    totals={k:0.0 for k in fields-{'version','valid'}}
    for row in rows:
        require(isinstance(row,dict));t=row.get('serverTiming')
        require(isinstance(t,dict) and set(t)==fields and type(t['version']) is int and t['version']==1 and t['valid'] is True)
        require(all(finite(t[k]) for k in totals))
        for s in STAGES:
            require(type(t[s+'Calls']) is int and type(t[s+'Failures']) is int and t[s+'Failures'] <= t[s+'Calls'])
            require(t[s+'Calls'] > 0 or t[s+'Seconds']==0)
        require(t['sleepSeconds'] <= t['holdSeconds']+1e-6)
        require(sum(t[s+'Seconds'] for s in STAGES if s!='sleep') <= t['totalSeconds']+1e-6)
        require(t['sleepCalls'] > 0 or t['sleepRequestedSeconds']==0)
        for k in totals: totals[k]+=t[k]
    return dict(version=1, complete=True, requests=len(rows), sums=totals,
        interpretation='Same-server monotonic durations. Sleep is nested in hold; concurrent request totals are not wall time. Writes do not prove client receipt or display.',
        capabilityAccepted=False)
''')
p=Path('tool/playback_network/network_profile.py');s=p.read_text();s=s.replace('class Shaper:', 'from contextlib import nullcontext\nfrom server_timing import RequestTiming\n\n\nclass Shaper:',1)
a=s.index('    def consume(self, count, deadline):');b=s.index('\n\ndef load_assets',a)
s=s[:a]+'''    def consume(self, count, deadline, timing=None):
        with timing.measure('queue') if timing else nullcontext():
            while True:
                elapsed, _, _ = self.state(deadline)
                if self.lock.acquire(timeout=min(.05, deadline-elapsed)):
                    break
        try:
            with timing.measure('hold') if timing else nullcontext():
                remaining = float(count)
                while remaining > 1e-7:
                    elapsed, step, boundary = self.state(deadline)
                    rate = step['bytesPerSecond']
                    duration = min(boundary - elapsed, .05,
                                   remaining / rate if rate else math.inf)
                    if timing: timing.requested_sleep(duration)
                    with timing.measure('sleep') if timing else nullcontext():
                        self.sleep(duration)
                    # Scheduled time only: oversleep never creates burst credit.
                    remaining -= duration * rate
                self.state(deadline)
        finally:
            self.lock.release()
'''+s[b:]
s=s.replace('        started = s.elapsed()\n        row = dict', '        timing = RequestTiming(s.now)\n        started = s.elapsed()\n        row = dict')
s=s.replace('            if active:\n                s.begin(deadline)','            if active:\n                with timing.measure(\'latency\'):\n                    s.begin(deadline)')
s=s.replace('            self.end_headers()','            with timing.measure(\'headerWrite\'):\n                self.end_headers()')
s=s.replace('                    s.consume(len(chunk), deadline)\n                    self.wfile.write(chunk)',"                    s.consume(len(chunk), deadline, timing)\n                    with timing.measure('bodyWrite'):\n                        self.wfile.write(chunk)")
s=s.replace("            row['endMs'] = round(s.elapsed() * 1000, 6) if active else None","            row['endMs'] = round(s.elapsed() * 1000, 6) if active else None\n            row['serverTiming'] = timing.finish()")
p.write_text(s)
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text().replace("receipt['connectionObservation'] = summarize_connections(\n                    read_rows(out/'requests.jsonl'), receipt['connectionMode'])","receipt['connectionObservation'] = summarize_connections(\n                    read_rows(out/'requests.jsonl'), receipt['connectionMode'])\n                from server_timing import summarize_server_timing\n                receipt['serverTimingObservation'] = summarize_server_timing(read_rows(out/'requests.jsonl'))").replace("'connection evidence incomplete'","'connection or server timing evidence incomplete'");p.write_text(s)
p=Path('tool/playback_network/test_abr_device.py');p.write_text(p.read_text().replace("'connection evidence incomplete'","'connection or server timing evidence incomplete'"))
p=Path('docs/superpowers/plans/2026-10-29-server-timing.md');p.write_text('''# 服务器整形与写出成本排查

基线35819ab9；继续用户已授权排查，沿用TDD、系统排障与集中验收，用户确认准备后约9分钟前台真机采集。不发布、不修改生产ABR门槛。

- [ ] 真实并发红绿复现并修复整形共享锁排队不检查deadline/stop；不改变额度或补偿oversleep。
- [ ] 添加有界同服务器时钟的latency/queue/hold/sleep/headerWrite/bodyWrite指标、次数/失败和计划休眠；sleep为hold子区间，不重复加总。缺失/非法/矛盾证据拒绝。
- [ ] 统一工具与消费者验证、一次独立复审；原配置、HTTP1.1关闭、HTTP1.1复用三轮同制品对照。
- [ ] 保留原始失败、设备授权缺口与旧快速取消关联缺口，完整归档并更新台账；只依据证据修复确认的问题。
''')
