import http.server,threading,socket,subprocess,json
from pathlib import Path
r=Path('/private/tmp/yl-budget-metrics');records=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  records.append(dict(attempt=len(records)+1))
  if len(records)==1:
   self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
  self.send_response(200);self.send_header('Content-Length','4');self.end_headers();self.wfile.write(b'test')
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);t=threading.Thread(target=s.serve_forever);t.start()
try:
 p=subprocess.run(['swift',str(r/'retry-probe.swift'),'http://127.0.0.1:'+str(s.server_port)+'/owned'],capture_output=True,text=True,timeout=45)
 (r/'retry-probe.stdout').write_text(p.stdout);(r/'retry-probe.stderr').write_text(p.stderr);(r/'retry-server.json').write_text(json.dumps(records,indent=2)+'\n');print('exit',p.returncode,p.stdout)
finally:s.shutdown();s.server_close();t.join()
