from pathlib import Path
import json,hashlib
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift');s=p.read_text()
old='''      case .paused:
        status = playRequested ? "buffering" : "ready"
      @unknown default:
        status = playRequested ? "buffering" : "ready"
'''
new='''      case .paused:
        // Item readiness can arrive after a route/user pause was acknowledged.
        // Keep that transport state; only initial nonplaying readiness is "ready".
        status = playRequested ? "buffering" : (status == "paused" ? "paused" : "ready")
      @unknown default:
        status = playRequested ? "buffering" : (status == "paused" ? "paused" : "ready")
'''
assert s.count(old)==1;p.write_text(s.replace(old,new))
out=Path('/private/tmp/yl-public-policy');ids=json.loads((out/'source-identity.json').read_text())
for path in ids:
 data=Path(path).read_bytes();ids[path]=hashlib.sha256(data).hexdigest();(out/'capture-source'/path).write_bytes(data)
(out/'source-identity.json').write_text(json.dumps(ids,indent=2)+'\n')
s=(out/'run-reviewed.py').read_text().replace('reviewed-','pause-fixed-');(out/'run-pause-fixed.py').write_text(s)
s=(out/'run-reviewed-media.py').read_text().replace('reviewed-','pause-fixed-');(out/'run-pause-fixed-media.py').write_text(s)
