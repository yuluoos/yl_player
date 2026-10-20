"""CoreDevice transport for an explicitly selected owned acceptance app.

Only this run's fixed result names are read from the app's data container. Failed
copies never reuse an earlier local result. This transports evidence; existing
native identity and raw AV validators still decide whether it is acceptable.
"""
import json
import subprocess
import uuid
from pathlib import Path

class DeviceTransport:
    LIMITS={'status.json':65536,'rows.json':128*1024*1024,'unfinished.json':128*1024*1024}
    def __init__(self, device, bundle, run, output):
        if str(uuid.UUID(run)) != run or not device or not bundle:
            raise ValueError('invalid device run identity')
        self.device=device;self.bundle=bundle;self.run=run;self.output=Path(output)
        self.attempt=0

    def copy_command(self,name,destination):
        """Never consume an absolute device path or arbitrary log-provided name."""
        if name not in self.LIMITS:raise ValueError('unsupported evidence file')
        return ['xcrun','devicectl','device','copy','from','--device',self.device,
                '--domain-type','appDataContainer','--domain-identifier',self.bundle,
                '--source','tmp/p03-public-'+self.run+'/'+name,
                '--destination',str(destination),'--timeout','10']

    def read_json(self,name):
        """Return fresh bounded JSON, or None while a remote file is unavailable."""
        if name not in self.LIMITS:raise ValueError('unsupported evidence file')
        self.attempt+=1
        target=self.output/f'copy-{self.attempt:04d}-{name}'
        if target.exists():raise ValueError('copy destination already exists')
        command=self.copy_command(name,target)
        with (self.output/f'copy-{self.attempt:04d}.log').open('wb') as log:
            result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=15)
        if result.returncode!=0:return None
        if not target.is_file() or target.is_symlink() or target.stat().st_size>self.LIMITS[name]:
            raise ValueError('missing or oversized device evidence')
        value=json.loads(target.read_bytes())
        if name=='status.json' and (not isinstance(value,dict) or value.get('runId')!=self.run):
            raise ValueError('status belongs to another run')
        if name=='rows.json' and not isinstance(value,list):raise ValueError('invalid rows envelope')
        return value

    def launch_command(self,flutter,app):
        """Flutter supplies the required physical-device Debug/LLDB launch."""
        return [str(flutter),'run','--machine','--debug','--no-hot','--no-pub',
                '--use-application-binary='+str(app),'-d',self.device]

    def prepare(self,app,encoded_plan):
        """Install owned bytes and write a one-shot plan outside the frozen bundle."""
        if len(encoded_plan.encode())>1024*1024:raise ValueError('plan exceeds bound')
        self.verify_target()
        plan_file=self.output/'device-plan.txt'
        plan_file.write_text(encoded_plan)
        commands=[['xcrun','devicectl','device','install','app','--device',self.device,str(app),'--timeout','90'],
                  ['xcrun','devicectl','device','copy','to','--device',self.device,
                   '--domain-type','appDataContainer','--domain-identifier',self.bundle,
                   '--source',str(plan_file),'--destination','tmp/p03-bound-plan.txt','--timeout','15']]
        for index,command in enumerate(commands):
            with (self.output/f'prepare-{index}.log').open('wb') as log:
                subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=100,check=True)

    def verify_target(self):
        """Reject simulators and aliases resolving to a different physical UDID."""
        raw=self.output/'device-info-raw.json'
        try:
            with (self.output/'device-info.log').open('wb') as log:
                subprocess.run(['xcrun','devicectl','device','info','details','--device',self.device,
                    '--json-output',str(raw),'--timeout','10'],stdout=log,
                    stderr=subprocess.STDOUT,timeout=15,check=True)
            if not raw.is_file() or raw.is_symlink() or raw.stat().st_size>1024*1024:
                raise ValueError('invalid device identity response')
            details=json.loads(raw.read_bytes())
            result=details.get('result',{}) if isinstance(details,dict) else {}
            hardware=result.get('hardwareProperties',{})
            if (not isinstance(hardware,dict) or hardware.get('reality')!='physical'
                or hardware.get('platform')!='iOS' or hardware.get('udid')!=self.device):
                raise ValueError('target is not the requested physical iOS device')
            properties=result.get('deviceProperties',{})
            identity=dict(udid=self.device,reality=hardware['reality'],platform=hardware['platform'],
                model=hardware.get('productType'),osVersion=properties.get('osVersionNumber'),
                osBuild=properties.get('osBuildUpdate'))
            (self.output/'device-identity.json').write_text(json.dumps(identity,sort_keys=True))
        finally:
            raw.unlink(missing_ok=True)

    def has_started(self,log_path):
        """An early native rejection must not interrupt Flutter's debugger attach."""
        events=self.events(log_path)
        ids={e.get('params',{}).get('appId') for e in events
             if e.get('event')=='app.start' and e.get('params',{}).get('deviceId')==self.device}
        return any(e.get('event')=='app.started' and e.get('params',{}).get('appId') in ids
                   for e in events)

    def stop(self,process,log_path):
        """Request Flutter's owned app.stop and require its successful reply."""
        events=self.events(log_path)
        ids=[e.get('params',{}).get('appId') for e in events
             if e.get('event')=='app.start' and e.get('params',{}).get('deviceId')==self.device]
        app_id=ids[-1] if ids else None
        if app_id and process.poll() is None:
            request=[dict(id=9901,method='app.stop',params=dict(appId=app_id))]
            try:
                process.stdin.write((json.dumps(request)+'\n').encode());process.stdin.flush()
                process.wait(timeout=20)
            except (OSError,subprocess.TimeoutExpired):pass
        if process.poll() is None:
            process.terminate()
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        return any(e.get('id')==9901 and e.get('result') is True for e in self.events(log_path))

    @staticmethod
    def events(path):
        events=[]
        for line in Path(path).read_text(errors='replace').splitlines():
            try:value=json.loads(line)
            except ValueError:continue
            for item in value if isinstance(value,list) else [value]:
                if isinstance(item,dict):events.append(item)
        return events
