#!/bin/bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
lock_file="$script_dir/ffmpeg-9.0.1.lock"
key_file="$script_dir/FFMPEG_RELEASE_KEY.asc"
bridge_root="$package_root/ios/native/YlFFmpegBridge"
output="$package_root/ios/yl_player_ios/Frameworks/YlFFmpegBridge.xcframework"

# shellcheck source=ffmpeg-9.0.1.lock
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
  --enable-demuxer=matroska
  --enable-protocol=file
  --enable-parser=aac,h264,hevc
  --enable-pic
  --enable-static
  --disable-shared
  --disable-symver
  --disable-gpl
  --disable-nonfree
)

print_contract() {
  printf '%s\n' \
    "FFMPEG_VERSION=$FFMPEG_VERSION" \
    "FFMPEG_URL=$FFMPEG_URL" \
    "FFMPEG_SHA256=$FFMPEG_SHA256" \
    "FFMPEG_SIGNING_KEY_FINGERPRINT=$FFMPEG_SIGNING_KEY_FINGERPRINT" \
    "IOS_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET" \
    "IOS_ARCHITECTURES=iphoneos-arm64,iphonesimulator-arm64,iphonesimulator-x86_64" \
    "FFMPEG_X86_64_FLAGS=--disable-x86asm"
  printf '%s\n' "${common_flags[@]}"
}

if [[ ${1:-} == "--print-contract" ]]; then
  print_contract
  exit 0
fi

for command_name in curl gpg lipo make plutil shasum tar xcodebuild xcrun; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "required build tool is missing: $command_name" >&2
    exit 1
  fi
done

work_root=$(mktemp -d "${TMPDIR:-/tmp}/yl_player_ffmpeg.XXXXXX")
archive="$work_root/ffmpeg-$FFMPEG_VERSION.tar.xz"
signature="$archive.asc"
source_root="$work_root/ffmpeg-$FFMPEG_VERSION"
build_root="$work_root/build"
gpg_home="$work_root/gnupg"
mkdir -p "$build_root" "$gpg_home"
chmod 700 "$gpg_home"

cleanup() {
  if [[ ${YL_KEEP_FFMPEG_BUILD:-0} == 1 ]]; then
    echo "kept FFmpeg build directory: $work_root"
  else
    rm -rf "$work_root"
  fi
}
trap cleanup EXIT

if [[ -n ${YL_FFMPEG_ARCHIVE:-} ]]; then
  cp "$YL_FFMPEG_ARCHIVE" "$archive"
else
  curl --fail --location --retry 3 --output "$archive" "$FFMPEG_URL"
fi
curl --fail --location --retry 3 --output "$signature" "$FFMPEG_SIGNATURE_URL"

actual_archive_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
[[ $actual_archive_sha == "$FFMPEG_SHA256" ]] || {
  echo "FFmpeg archive checksum mismatch" >&2
  exit 1
}
actual_key_sha=$(shasum -a 256 "$key_file" | awk '{print $1}')
[[ $actual_key_sha == "$FFMPEG_SIGNING_KEY_SHA256" ]] || {
  echo "FFmpeg signing key checksum mismatch" >&2
  exit 1
}

GNUPGHOME="$gpg_home" gpg --batch --quiet --import "$key_file"
actual_fingerprint=$(GNUPGHOME="$gpg_home" gpg --batch --with-colons --fingerprint \
  | awk -F: '$1 == "fpr" { print $10; exit }')
[[ $actual_fingerprint == "$FFMPEG_SIGNING_KEY_FINGERPRINT" ]] || {
  echo "FFmpeg signing key fingerprint mismatch" >&2
  exit 1
}
GNUPGHOME="$gpg_home" gpg --batch --verify "$signature" "$archive"

tar -xf "$archive" -C "$work_root"

build_slice() {
  local sdk=$1
  local apple_arch=$2
  local ffmpeg_arch=$3
  local minimum_flag=$4
  local slice_name="$sdk-$apple_arch"
  local slice_root="$build_root/$slice_name"
  local install_root="$slice_root/install"
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
    "$source_root/configure" \
      --prefix="$install_root" \
      --enable-cross-compile \
      --target-os=darwin \
      --arch="$ffmpeg_arch" \
      --cc="$clang" \
      --ar="$ar" \
      --ranlib="$ranlib" \
      --sysroot="$sdk_root" \
      --extra-cflags="-arch $apple_arch -isysroot $sdk_root $minimum_flag -fvisibility=hidden" \
      --extra-ldflags="-arch $apple_arch -isysroot $sdk_root $minimum_flag" \
      ${arch_flag:+"$arch_flag"} \
      "${common_flags[@]}"
    make -j"$(sysctl -n hw.logicalcpu)"
    make install
  )

  local framework="$slice_root/YlFFmpegBridge.framework"
  local object_file="$slice_root/YlFFmpegBridge.o"
  local exports_file="$slice_root/exports.txt"
  mkdir -p "$framework/Headers" "$framework/Modules"
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
  "$clang" -fobjc-arc -fvisibility=hidden -arch "$apple_arch" -isysroot "$sdk_root" \
    "$minimum_flag" -I"$install_root/include" -I"$bridge_root/include" \
    -c "$bridge_root/YlFFmpegBridge.m" -o "$object_file"
  "$clang" -dynamiclib -arch "$apple_arch" -isysroot "$sdk_root" "$minimum_flag" \
    -install_name @rpath/YlFFmpegBridge.framework/YlFFmpegBridge \
    -Wl,-dead_strip -Wl,-exported_symbols_list,"$exports_file" \
    "$object_file" \
    -Wl,-force_load,"$install_root/lib/libavformat.a" \
    -Wl,-force_load,"$install_root/lib/libavcodec.a" \
    -Wl,-force_load,"$install_root/lib/libavutil.a" \
    -framework CoreFoundation -framework CoreMedia -framework Foundation -framework Security \
    -o "$framework/YlFFmpegBridge"
  cp "$bridge_root/include/YlFFmpegBridge.h" "$framework/Headers/"
  cp "$bridge_root/module.modulemap" "$framework/Modules/"
  plutil -create xml1 "$framework/Info.plist"
  plutil -insert CFBundleExecutable -string YlFFmpegBridge "$framework/Info.plist"
  plutil -insert CFBundleIdentifier -string dev.ylplayer.YlFFmpegBridge "$framework/Info.plist"
  plutil -insert CFBundleName -string YlFFmpegBridge "$framework/Info.plist"
  plutil -insert CFBundlePackageType -string FMWK "$framework/Info.plist"
  plutil -insert CFBundleShortVersionString -string "$FFMPEG_VERSION" "$framework/Info.plist"
  plutil -insert CFBundleVersion -string 1 "$framework/Info.plist"
}

build_slice iphoneos arm64 aarch64 "-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET"
build_slice iphonesimulator arm64 aarch64 "-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"
build_slice iphonesimulator x86_64 x86_64 "-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"

device_framework="$build_root/iphoneos-arm64/YlFFmpegBridge.framework"
simulator_framework="$build_root/iphonesimulator/YlFFmpegBridge.framework"
mkdir -p "$(dirname "$simulator_framework")"
cp -R "$build_root/iphonesimulator-arm64/YlFFmpegBridge.framework" "$simulator_framework"
lipo -create \
  "$build_root/iphonesimulator-arm64/YlFFmpegBridge.framework/YlFFmpegBridge" \
  "$build_root/iphonesimulator-x86_64/YlFFmpegBridge.framework/YlFFmpegBridge" \
  -output "$simulator_framework/YlFFmpegBridge"

rm -rf "$output"
mkdir -p "$(dirname "$output")"
xcodebuild -create-xcframework \
  -framework "$device_framework" \
  -framework "$simulator_framework" \
  -output "$output"
echo "created $output"
