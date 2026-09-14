#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$script_dir" <<'PY'
import ctypes, hashlib, json, pathlib, plistlib, re, shlex, shutil, subprocess, sys, tempfile
script = pathlib.Path(sys.argv[1]); package = script.parent.parent
artifact = package / 'darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework'
assert artifact.is_dir(), 'combined YlFFmpegBridge.xcframework does not exist'
expected = {'ios-arm64': ('ios', None, {'arm64'}, '15.0'),
 'ios-arm64_x86_64-simulator': ('ios', 'simulator', {'arm64','x86_64'}, '15.0'),
 'macos-arm64_x86_64': ('macos', None, {'arm64','x86_64'}, '12.0')}
info = plistlib.loads((artifact/'Info.plist').read_bytes())['AvailableLibraries']
assert [x['LibraryIdentifier'] for x in info] == sorted(expected), 'noncanonical library order or incorrect slices'
source = package/'darwin/native/YlFFmpegBridge'
pins = dict(line.split('=',1) for line in (script/'ffmpeg-9.0.1.lock').read_text().splitlines())
assert pins == {'FFMPEG_VERSION':'9.0.1', 'FFMPEG_URL':'https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz',
 'FFMPEG_SIGNATURE_URL':'https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz.asc',
 'FFMPEG_SHA256':'cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635',
 'FFMPEG_SIGNING_KEY_FINGERPRINT':'FCF986EA15E6E293A5644F10B4322F04D67658D8',
 'FFMPEG_SIGNING_KEY_SHA256':'397b3becedcd5a98769967ff1ff8501ddc89f8368b8f766e4701377d7dbaabe5',
 'IOS_DEPLOYMENT_TARGET':'15.0', 'MACOS_DEPLOYMENT_TARGET':'12.0'}
allowed_enables = {'--enable-cross-compile','--enable-avutil','--enable-avcodec','--enable-avformat',
 '--enable-demuxer=matroska,flv,mov,mpegts','--enable-decoder=dca','--enable-protocol=file','--enable-parser=aac,h264,hevc,mpegaudio,dca',
 '--enable-pic','--enable-static'}
required_disables = {'--disable-everything','--disable-autodetect','--disable-network',
 '--disable-programs','--disable-doc','--disable-avdevice','--disable-avfilter','--disable-swscale',
 '--disable-swresample','--disable-encoders','--disable-decoders','--disable-muxers',
 '--disable-shared','--disable-symver','--disable-gpl','--disable-nonfree'}
def check_configuration(text):
 args=set(shlex.split(text))
 assert {a for a in args if a.startswith('--enable-')}==allowed_enables
 assert required_disables <= args
 assert '--prefix=/yl_ffmpeg/install' in args
 assert '/yl-apple-ffmpeg.' not in text

repo = package.parent.parent
symbols = set()
for platform in ('ios', 'macos', 'apple'):
 for f in (repo/f'packages/yl_player_{platform}').rglob('*.swift'):
  symbols.update(re.findall(r'\b(ylf_\w+)\s*\(', f.read_text()))
assert symbols, 'must discover actual Swift bridge consumers'
for entry in info:
 platform, variant, archs, minimum = expected[entry['LibraryIdentifier']]
 assert entry['SupportedPlatform'] == platform
 assert entry.get('SupportedPlatformVariant') == variant
 assert set(entry['SupportedArchitectures']) == archs
 f = artifact/entry['LibraryIdentifier']/entry['LibraryPath']; binary = f/'YlFFmpegBridge'
 assert set(subprocess.check_output(['lipo','-archs',str(binary)],text=True).split()) == archs
 assert (f/'Headers/YlFFmpegBridge.h').read_bytes() == (source/'include/YlFFmpegBridge.h').read_bytes()
 assert (f/'Modules/module.modulemap').read_bytes() == (source/'module.modulemap').read_bytes()
 for arch in sorted(archs):
  exports = subprocess.check_output(['nm','-arch',arch,'-gU',str(binary)],text=True)
  names = {line.split()[-1] for line in exports.splitlines() if line.split()}
  # Inspect each thin binary's embedded FFmpeg configuration, not just script output.
  with tempfile.TemporaryDirectory(prefix='yl-apple-thin-') as temporary:
   thin=pathlib.Path(temporary)/'bridge'
   if len(archs)>1: subprocess.run(['lipo',str(binary),'-thin',arch,'-output',str(thin)],check=True)
   else: shutil.copyfile(binary,thin)
   assert b'yl-apple-ffmpeg.' not in thin.read_bytes(), 'temporary build path leaked into binary'
   strings=subprocess.check_output(['strings','-a',str(thin)],text=True)
   configs=[line for line in strings.splitlines() if line.startswith('--prefix=')]
   assert len(configs)==1
   check_configuration(configs[0])
  assert {'_'+s for s in symbols} <= names, (arch, symbols, names)
  loads = subprocess.check_output(['otool','-arch',arch,'-l',str(binary)],text=True)
  assert len(re.findall(r'cmd LC_UUID\n',loads)) == 1, 'dyld requires a UUID load command'
  builds = re.findall(r'cmd LC_BUILD_VERSION\n(.*?)(?=Load command|\Z)',loads,re.S)
  assert len(builds) == 1 and re.search(r'\bminos '+re.escape(minimum)+r'\b',builds[0]), loads
  assert '@rpath/YlFFmpegBridge.framework/' + ('Versions/A/' if platform=='macos' else '') + 'YlFFmpegBridge' in loads
 if platform == 'macos':
  for p,t in {'Versions/Current':'A','YlFFmpegBridge':'Versions/Current/YlFFmpegBridge','Headers':'Versions/Current/Headers','Modules':'Versions/Current/Modules','Resources':'Versions/Current/Resources'}.items():
   assert (f/p).is_symlink() and (f/p).readlink().as_posix() == t
mac = artifact/'macos-arm64_x86_64/YlFFmpegBridge.framework/YlFFmpegBridge'
lib=ctypes.CDLL(str(mac))
lib.ylf_ffmpeg_version.restype=ctypes.c_char_p
lib.ylf_build_configuration.restype=ctypes.c_char_p
assert lib.ylf_ffmpeg_version().decode()=='9.0.1'
check_configuration(lib.ylf_build_configuration().decode())
lock = script/'bridge-artifact.lock'
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
before = digest(lock)
subprocess.run(['python3',str(script/'verify_artifact.py')],check=True)
assert digest(lock) == before, 'verification rewrote lock'
# Real copied package mutations exercise failure and preservation, never the working artifact.
with tempfile.TemporaryDirectory(prefix='yl-apple-contract-') as root:
 copy = pathlib.Path(root)/'yl_player_apple'; shutil.copytree(package,copy,symlinks=True)
 copied_script = copy/'tool/apple_ffmpeg'; copied_lock = copied_script/'bridge-artifact.lock'
 mutations = [('source',copy/'darwin/native/YlFFmpegBridge/YlFFmpegBridge.m',lambda b:b+b'\n// corruption\n'),
  ('configuration',copied_script/'build_xcframework.sh',lambda b:b.replace(b'--enable-demuxer=matroska,flv,mov',b'--enable-demuxer=matroska,flv,mov,avi')),
  ('slice',copy/'darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework/ios-arm64/YlFFmpegBridge.framework/YlFFmpegBridge',lambda b:b[:4096]+bytes([b[4096]^1])+b[4097:])]
 for name,path,mutate in mutations:
  original=path.read_bytes(); changed=mutate(original); assert changed!=original
  path.write_bytes(changed)
  for mode in ('immutable-verify',):
   command = ['python3',str(copied_script/'verify_artifact.py')] if mode == 'immutable-verify' else ['sh',str(copied_script/'build_xcframework.sh'),mode]
   result=subprocess.run(command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
   print(f'NEGATIVE {name} {mode} exit={result.returncode}\n{result.stdout}',flush=True)
   reason = 'artifact mismatch' if name == 'slice' else 'input mismatch' if mode == 'immutable-verify' else 'inputs mismatch'
   assert result.returncode != 0 and reason in result.stdout, (name, mode, reason)
   assert digest(copied_lock)==before, 'failed verification refreshed lock'
  path.write_bytes(original)
assert digest(lock)==before
print(f'Apple FFmpeg contract passed: 3 slices, 5 architectures, {len(symbols)} Swift symbols, 3 intended-reason negative checks; lock unchanged.')
PY
