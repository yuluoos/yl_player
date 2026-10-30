import socket,struct,threading,subprocess,json,time
from pathlib import Path
r=Path('/private/tmp/yl-triggered-downshift');results=[]
for mode in ['normal','before-parse','after-parse']:
 s=socket.socket();s.bind(('127.0.0.1',0));s.listen(8);s.settimeout(.2);stop=threading.Event();accepted=[];parsed=[]
 def serve():
  while not stop.is_set():
   try:c,_=s.accept()
   except socket.timeout:continue
   except OSError:return
   index=len(accepted)+1;accepted.append(index);c.settimeout(2)
   try:
    if mode=='before-parse' and index==1:
     c.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0));continue
    data=b''
    while b'\r\n\r\n' not in data and len(data)<8192:
     chunk=c.recv(1024)
     if not chunk:break
     data+=chunk
    if b'\r\n\r\n' in data:parsed.append(index)
    if mode=='after-parse' and index==1:
     c.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0));continue
    c.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndata')
   except OSError:pass
   finally:c.close()
 t=threading.Thread(target=serve);t.start()
 command=['swift',str(r/'session-metrics.swift'),f'http://127.0.0.1:{s.getsockname()[1]}/owned']
 p=subprocess.run(command,capture_output=True,text=True,timeout=45);stop.set();s.close();t.join(3)
 (r/(mode+'-session.stdout')).write_text(p.stdout);(r/(mode+'-session.stderr')).write_text(p.stderr)
 row=dict(mode=mode,platform='macOS',accepted=accepted,parsed=parsed,exitCode=p.returncode,command=command,
          historicalCauseProven=False,capabilityAccepted=False)
 if p.returncode==0:row['metrics']=json.loads(p.stdout)
 results.append(row);print(mode,p.returncode,accepted,parsed,flush=True)
(r/'preparse-probe-results.json').write_text(json.dumps(results,indent=2)+'\n')
