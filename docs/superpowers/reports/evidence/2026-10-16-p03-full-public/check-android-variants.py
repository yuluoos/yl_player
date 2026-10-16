from pathlib import Path
import json,zipfile,hashlib,io
scratch=Path('/private/tmp/yl-p03-full-public-20261016')
base=Path('/Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player/example/build/yl_player_android')
result=json.loads((scratch/'android-opt-in-classes.json').read_text())
def observed(name):return any(key in name for key in ('YlBoundFlutterProbe','YlBoundMedia3Audio','YlBoundAVInstrumentedTest'))
result['observationClasses']=[n for n in result['observationClasses'] if observed(n)]
assert result['observationClasses']
items={'opted-in-public-debug':result}
for name,p in [('ordinary-debug',base/'intermediates/runtime_library_classes_jar/debug/bundleLibRuntimeToJarDebug/classes.jar'),('release-even-with-opt-in',base/'outputs/aar/yl_player_android-release.aar')]:
 data=p.read_bytes();z=zipfile.ZipFile(io.BytesIO(data))
 if p.suffix=='.aar':z=zipfile.ZipFile(io.BytesIO(z.read('classes.jar')))
 classes=z.namelist();assert any('YlPlayerAndroidPlugin.class' in n for n in classes)
 capture=[n for n in classes if observed(n)];assert not capture,(name,capture)
 items[name]=dict(path=str(p),sha256=hashlib.sha256(data).hexdigest(),observationClasses=capture,productPluginPresent=True)
(scratch/'android-variant-absence.json').write_text(json.dumps(items,indent=2)+'\n')
print('Android opt-in present; ordinary debug and release absent')
