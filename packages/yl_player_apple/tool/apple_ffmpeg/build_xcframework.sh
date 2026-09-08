#!/bin/sh
# The public interface accepts `sh build_xcframework.sh` on macOS.
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
lock_file="$script_dir/ffmpeg-9.0.1.lock"
key_file="$script_dir/FFMPEG_RELEASE_KEY.asc"
bridge_root="$package_root/darwin/native/YlFFmpegBridge"
output="$package_root/darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework"
artifact_lock="$script_dir/bridge-artifact.lock"
source "$lock_file"

common_flags=(
  --disable-everything
  --disable-autodetect
  --disable-network
  --disable-programs
  --disable-doc
  --disable-avdevice
  --disable-avfilter
  --disable-swscale
  --disable-swresample
  --disable-encoders
  --disable-decoders
  --disable-muxers
  --enable-avutil
  --enable-avcodec
  --enable-avformat
  --enable-demuxer=matroska,flv
  --enable-protocol=file
  --enable-parser=aac,h264,hevc,mpegaudio
  --enable-pic
  --enable-static
  --disable-shared
  --disable-symver
  --disable-gpl
  --disable-nonfree
)


print_contract() {
  cat "$lock_file"
  printf '%s\n' "${common_flags[@]}" \
    'FFMPEG_X86_64_FLAGS=--disable-x86asm' \
    'NORMALIZATION=relative-source,fixed-install-prefix,prefix-map,bridge-no-debug,zero-ar-date,linker-content-uuid,oso-prefix,sorted-plist-libraries' \
    'TARGETS=iphoneos-arm64,iphonesimulator-arm64,iphonesimulator-x86_64,macosx-arm64,macosx-x86_64'
}

# A lock describes complete file bytes (including Mach-O signing data), and
# symlink targets. Nothing in a binary is omitted from comparison.
manifest() {
  python3 - "$package_root" "$1" "$2" "$3" "${4:-}" <<'PYMANIFEST'
import hashlib,json,os,pathlib,subprocess,sys
package,artifact,action,lock,receipt=map(pathlib.Path,sys.argv[1:])
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def run(*args): return subprocess.check_output(args,text=True).strip()
inputs={p:sha(package/p) for p in ['darwin/native/YlFFmpegBridge/YlFFmpegBridge.m',
 'darwin/native/YlFFmpegBridge/include/YlFFmpegBridge.h',
 'darwin/native/YlFFmpegBridge/module.modulemap','tool/apple_ffmpeg/ffmpeg-9.0.1.lock',
 'tool/apple_ffmpeg/FFMPEG_RELEASE_KEY.asc','tool/apple_ffmpeg/build_xcframework.sh']}
toolchain={'xcode':run('xcodebuild','-version'),'clang':run('xcrun','clang','--version')}
for name in ['clang','ld','ar','ranlib']:
 p=pathlib.Path(run('xcrun','--find',name));toolchain[name+'_path']=str(p);toolchain[name+'_sha256']=sha(p)
for sdk in ['iphoneos','iphonesimulator','macosx']:
 p=pathlib.Path(run('xcrun','--sdk',sdk,'--show-sdk-path'))
 toolchain[sdk]={'path':str(p),'version':run('xcrun','--sdk',sdk,'--show-sdk-version'),
  'build':run('xcrun','--sdk',sdk,'--show-sdk-build-version'),'settings_sha256':sha(p/'SDKSettings.json')}
contract=run('bash',str(package/'tool/apple_ffmpeg/build_xcframework.sh'),'--print-contract').splitlines()
files={}
for p in sorted(artifact.rglob('*')):
 relative=p.relative_to(artifact).as_posix()
 if p.is_symlink(): files[relative]={'symlink':os.readlink(p)}
 elif p.is_file():files[relative]={'sha256':sha(p),'size':p.stat().st_size}
assert files, 'artifact mismatch: empty or absent XCFramework'
current={'schema':1,'inputs':inputs,'configure_contract':contract,'toolchain':toolchain,'files':files}
if str(action)=='write':
 current['signed_source']=json.loads(receipt.read_text())
 lock.write_text(json.dumps(current,indent=2,sort_keys=True)+'\n')
 print('Candidate manifest written; requires independent --rebuild-check before acceptance.')
else:
 expected=json.loads(lock.read_text())
 for field,value in current.items():
  if expected.get(field)!=value:
   print(f'{field} mismatch',file=sys.stderr)
   if isinstance(value,dict):
    for key in sorted(set(value)|set(expected.get(field,{}))):
     if value.get(key)!=expected.get(field,{}).get(key): print(f'  {key}: expected={expected.get(field,{}).get(key)!r} actual={value.get(key)!r}',file=sys.stderr)
   sys.exit(1)
 if receipt.is_file() and expected['signed_source']!=json.loads(receipt.read_text()):
  sys.exit('signed source mismatch')
 print(f'Verified {len(files)} canonical file/symlink entries, source/configuration and toolchain; lock unchanged.')
PYMANIFEST
}

mode=${1:---verify}
case "$mode" in
 --print-contract) print_contract; exit 0 ;;
 --verify|--rebuild-check)
   [[ $# -le 2 ]] || { echo 'too many arguments' >&2; exit 2; }
   if [[ -n ${2:-} ]]; then output="$2/YlFFmpegBridge.xcframework"; artifact_lock="$2/bridge-artifact.lock"; fi
   # Detect any local corruption before downloading or compiling anything.
   manifest "$output" compare "$artifact_lock"
   ;;
 --build-candidate)
   [[ $# == 2 && ! -e $2 ]] || { echo 'usage: --build-candidate NEW_DIRECTORY (never writes committed artifact/lock)' >&2; exit 2; }
   candidate=$2
   ;;
 *) echo 'usage: --verify [CANDIDATE_DIRECTORY] | --rebuild-check [CANDIDATE_DIRECTORY] | --build-candidate NEW_DIRECTORY | --print-contract' >&2; exit 2 ;;
esac

work_root=$(mktemp -d "${TMPDIR:-/tmp}/yl-apple-ffmpeg.XXXXXX")
cleanup() {
 if [[ ${YL_KEEP_FFMPEG_BUILD:-0} == 1 ]]; then echo "kept FFmpeg build directory: $work_root"; else rm -rf "$work_root"; fi
}
trap cleanup EXIT
archive="$work_root/ffmpeg-$FFMPEG_VERSION.tar.xz"
signature="$archive.asc"
source_root="$work_root/ffmpeg-$FFMPEG_VERSION"
build_root="$work_root/build"
gpg_home="$work_root/gnupg"
mkdir -p "$gpg_home" "$build_root"
chmod 700 "$gpg_home"
if [[ -n ${YL_FFMPEG_ARCHIVE:-} ]]; then cp "$YL_FFMPEG_ARCHIVE" "$archive"; else curl --fail --location --retry 3 --output "$archive" "$FFMPEG_URL"; fi
if [[ -n ${YL_FFMPEG_SIGNATURE:-} ]]; then cp "$YL_FFMPEG_SIGNATURE" "$signature"; else curl --fail --location --retry 3 --output "$signature" "$FFMPEG_SIGNATURE_URL"; fi
[[ $(shasum -a 256 "$archive" | awk '{print $1}') == "$FFMPEG_SHA256" ]] || { echo 'source archive checksum mismatch' >&2; exit 1; }
[[ $(shasum -a 256 "$key_file" | awk '{print $1}') == "$FFMPEG_SIGNING_KEY_SHA256" ]] || { echo 'signing key checksum mismatch' >&2; exit 1; }
GNUPGHOME="$gpg_home" gpg --batch --no-autostart --quiet --import "$key_file"
GNUPGHOME="$gpg_home" gpg --batch --no-autostart --status-fd 1 --verify "$signature" "$archive" > "$work_root/signature.status"
cat "$work_root/signature.status"
python3 - "$archive" "$signature" "$work_root/signature.status" "$FFMPEG_SIGNING_KEY_FINGERPRINT" "$work_root/signed-source.json" <<'PYSIGN'
import hashlib,json,pathlib,sys
archive,signature,status,fingerprint,output=sys.argv[1:]
lines=pathlib.Path(status).read_text().splitlines()
valid=[x.split()[2:] for x in lines if x.startswith('[GNUPG:] VALIDSIG ')]
assert len(valid)==1 and (valid[0][0]==fingerprint or valid[0][-1]==fingerprint), 'source signature fingerprint mismatch'
pathlib.Path(output).write_text(json.dumps({'archive_sha256':hashlib.sha256(pathlib.Path(archive).read_bytes()).hexdigest(),
 'signature_sha256':hashlib.sha256(pathlib.Path(signature).read_bytes()).hexdigest(),'validsig':valid[0]},sort_keys=True)+'\n')
PYSIGN
if [[ $mode == --verify ]]; then manifest "$output" compare "$artifact_lock" "$work_root/signed-source.json"; exit 0; fi

tar -xf "$archive" -C "$work_root"
cp -R "$bridge_root" "$work_root/bridge"
# Keep archive member timestamps and tool locale independent of the host.
export ZERO_AR_DATE=1 LC_ALL=C SOURCE_DATE_EPOCH=0
build_slice() {
  local sdk=$1
  local apple_arch=$2
  local ffmpeg_arch=$3
  local minimum_flag=$4
  local slice_name="$sdk-$apple_arch"
  local slice_root="$build_root/$slice_name"
  local install_root="$slice_root/stage/yl_ffmpeg/install"
  local sdk_root
  local clang
  local ar
  local ranlib
  local arch_flag=
  sdk_root=$(xcrun --sdk "$sdk" --show-sdk-path)
  clang=$(xcrun --sdk "$sdk" --find clang)
  ar=$(xcrun --sdk "$sdk" --find ar)
  ranlib=$(xcrun --sdk "$sdk" --find ranlib)
  if [[ $ffmpeg_arch == x86_64 ]]; then
    arch_flag=--disable-x86asm
  fi
  mkdir -p "$slice_root"

  (
    cd "$slice_root"
    "../../ffmpeg-$FFMPEG_VERSION/configure" \
      --prefix=/yl_ffmpeg/install \
      --enable-cross-compile \
      --target-os=darwin \
      --arch="$ffmpeg_arch" \
      --cc="$clang" \
      --ar="$ar" \
      --ranlib="$ranlib" \
      --sysroot="$sdk_root" \
      --extra-cflags="-arch $apple_arch -isysroot $sdk_root $minimum_flag -fvisibility=hidden -g0 -ffile-prefix-map=../../ffmpeg-$FFMPEG_VERSION=/yl_ffmpeg/src -fdebug-compilation-dir=/yl_ffmpeg/build/$slice_name" \
      --extra-ldflags="-arch $apple_arch -isysroot $sdk_root $minimum_flag" \
      ${arch_flag:+"$arch_flag"} \
      "${common_flags[@]}"
    make -j"${YL_FFMPEG_JOBS:-4}"
    make install DESTDIR="$slice_root/stage"
  )

  local framework="$slice_root/YlFFmpegBridge.framework"
  local object_file="$slice_root/YlFFmpegBridge.o"
  local exports_file="$slice_root/exports.txt"
  local contents="$framework"
  local plist="$framework/Info.plist"
  local install_name=@rpath/YlFFmpegBridge.framework/YlFFmpegBridge
  local identifier=dev.ylplayer.YlFFmpegBridge
  if [[ $sdk == macosx ]]; then
    contents="$framework/Versions/A"
    plist="$contents/Resources/Info.plist"
    install_name=@rpath/YlFFmpegBridge.framework/Versions/A/YlFFmpegBridge
    identifier=dev.ylplayer.macos.YlFFmpegBridge
    mkdir -p "$contents/Resources"
  fi
  mkdir -p "$contents/Headers" "$contents/Modules"
  printf '%s\n' \
    _ylf_build_configuration \
    _ylf_ffmpeg_version \
    _ylf_open_local \
    _ylf_open_callbacks \
    _ylf_copy_stream_info \
    _ylf_stream_codec_config_size \
    _ylf_copy_stream_codec_config \
    _ylf_read_packet \
    _ylf_seek \
    _ylf_close \
    _ylf_packet_stream_index \
    _ylf_packet_pts_us \
    _ylf_packet_dts_us \
    _ylf_packet_duration_us \
    _ylf_packet_size \
    _ylf_packet_data \
    _ylf_packet_is_keyframe \
    _ylf_packet_release \
    _ylf_debug_outstanding_packet_count \
    _ylf_copy_video_format_description \
    _ylf_copy_video_format_description_from_codec_config \
    _ylf_create_video_sample_buffer \
    >"$exports_file"
  (
  cd "$slice_root"
  "$clang" -fobjc-arc -fvisibility=hidden -arch "$apple_arch" -isysroot "$sdk_root" \
    "$minimum_flag" -I"$install_root/include" -I"$bridge_root/include" \
    -g0 -ffile-prefix-map=../../bridge=/yl_ffmpeg/bridge -fdebug-compilation-dir=/yl_ffmpeg/build/$slice_name \
    -c ../../bridge/YlFFmpegBridge.m -o "$object_file"
  "$clang" -dynamiclib -arch "$apple_arch" -isysroot "$sdk_root" "$minimum_flag" \
    -install_name "$install_name" -Wl,-oso_prefix,"$work_root/" \
    -Wl,-dead_strip -Wl,-exported_symbols_list,"$exports_file" \
    "$object_file" \
    -Wl,-force_load,"$install_root/lib/libavformat.a" \
    -Wl,-force_load,"$install_root/lib/libavcodec.a" \
    -Wl,-force_load,"$install_root/lib/libavutil.a" \
    -framework CoreFoundation -framework CoreMedia -framework Foundation -framework Security \
    -o "$contents/YlFFmpegBridge"
  )
  cp "$bridge_root/include/YlFFmpegBridge.h" "$contents/Headers/"
  cp "$bridge_root/module.modulemap" "$contents/Modules/"
  plutil -create xml1 "$plist"
  plutil -insert CFBundleExecutable -string YlFFmpegBridge "$plist"
  plutil -insert CFBundleIdentifier -string "$identifier" "$plist"
  plutil -insert CFBundleName -string YlFFmpegBridge "$plist"
  plutil -insert CFBundlePackageType -string FMWK "$plist"
  plutil -insert CFBundleShortVersionString -string "$FFMPEG_VERSION" "$plist"
  plutil -insert CFBundleVersion -string 1 "$plist"
  if [[ $sdk == macosx ]]; then
    plutil -insert LSMinimumSystemVersion -string "$MACOS_DEPLOYMENT_TARGET" "$plist"
    ln -s A "$framework/Versions/Current"
    ln -s Versions/Current/YlFFmpegBridge "$framework/YlFFmpegBridge"
    ln -s Versions/Current/Headers "$framework/Headers"
    ln -s Versions/Current/Modules "$framework/Modules"
    ln -s Versions/Current/Resources "$framework/Resources"
  fi
}

build_slice iphoneos arm64 aarch64 "-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET"
build_slice iphonesimulator arm64 aarch64 "-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"
build_slice iphonesimulator x86_64 x86_64 "-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"
build_slice macosx arm64 aarch64 "-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET"
build_slice macosx x86_64 x86_64 "-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET"
for sdk in iphonesimulator macosx; do
 framework="$build_root/$sdk/YlFFmpegBridge.framework"
 mkdir -p "$(dirname "$framework")"
 cp -R "$build_root/$sdk-arm64/YlFFmpegBridge.framework" "$framework"
 binary=YlFFmpegBridge
 [[ $sdk != macosx ]] || binary=Versions/A/YlFFmpegBridge
 lipo -create "$build_root/$sdk-arm64/YlFFmpegBridge.framework/$binary" \
  "$build_root/$sdk-x86_64/YlFFmpegBridge.framework/$binary" -output "$framework/$binary"
done
rebuilt="$work_root/YlFFmpegBridge.xcframework"
xcodebuild -create-xcframework \
 -framework "$build_root/iphoneos-arm64/YlFFmpegBridge.framework" \
 -framework "$build_root/iphonesimulator/YlFFmpegBridge.framework" \
 -framework "$build_root/macosx/YlFFmpegBridge.framework" -output "$rebuilt"
# xcodebuild emits AvailableLibraries in nondeterministic completion order.
# Canonicalize the produced plist itself; verification still hashes every byte.
python3 - "$rebuilt/Info.plist" <<'PYPLIST'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1]);info=plistlib.loads(p.read_bytes())
info['AvailableLibraries'].sort(key=lambda entry:entry['LibraryIdentifier'])
p.write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_XML,sort_keys=True))
PYPLIST
if [[ $mode == --rebuild-check ]]; then
 manifest "$rebuilt" compare "$artifact_lock" "$work_root/signed-source.json"
 echo 'Clean signed five-target rebuild matches every canonical artifact byte; committed output and lock unchanged.'
else
 mkdir -p "$candidate"
 cp -R "$rebuilt" "$candidate/YlFFmpegBridge.xcframework"
 manifest "$candidate/YlFFmpegBridge.xcframework" write "$candidate/bridge-artifact.lock" "$work_root/signed-source.json"
 echo "Candidate: $candidate. Run --rebuild-check '$candidate', review provenance/differences, then explicitly copy artifact and lock."
fi
