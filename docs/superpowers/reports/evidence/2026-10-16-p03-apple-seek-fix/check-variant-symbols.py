import hashlib,json,subprocess
from pathlib import Path
root=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player')
scratch=Path('/private/tmp/yl-p03-seek-fix-20261016')
paths={
 'ordinary-debug':root/'packages/yl_player/example/build/native-macos-tests/Build/Products/Debug/yl_player_example.app/Contents/MacOS/yl_player_example.debug.dylib',
 'opted-in-debug':scratch/'build-public/Build/Products/Debug/yl_player_example.app/Contents/MacOS/yl_player_example.debug.dylib',
 'release-with-opt-in-define':scratch/'build-release/Build/Products/Release/yl_player_example.app/Contents/MacOS/yl_player_example'}
result={}
for name,p in paths.items():
 output=subprocess.check_output(['nm','-j',str(p)],text=True)
 counts={key:sum(key in line for line in output.splitlines()) for key in ['YlBoundFlutterProbe','YlBoundDisplayReadback','YlBoundWindowVisibility']}
 registry='YlApplePlayerRegistry' in output
 assert registry,name
 assert all(n>0 for n in counts.values()) if name=='opted-in-debug' else not any(counts.values()),name
 result[name]={'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'symbolCounts':counts,'productRegistryPresent':registry}
(scratch/'variant-absence.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
