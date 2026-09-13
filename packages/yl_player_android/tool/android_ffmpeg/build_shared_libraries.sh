#!/bin/sh
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
lock_file="$script_dir/ffmpeg-9.0.1.lock"
source "$lock_file"

abis=(arm64-v8a armeabi-v7a x86_64)
common_flags=(
  --disable-everything
  --disable-autodetect
  --disable-network
  --disable-programs
  --disable-doc
  --disable-avdevice
  --disable-avfilter
  --disable-swscale
  --disable-encoders
  --disable-muxers
  --enable-avutil
  --enable-avcodec
  --enable-avformat
  --enable-swresample
  --enable-demuxer=matroska,flv,mov,mpegts,aac,mp3,ogg
  --enable-decoder=h264,hevc,aac,mp3,ac3,eac3,dca,flac,opus,vorbis
  --enable-parser=aac,ac3,dca,flac,h264,hevc,mpegaudio,opus,vorbis
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc
  --enable-protocol=file
  --enable-pic
  --enable-static
  --disable-shared
  --disable-symver
  --disable-gpl
  --disable-nonfree
)

print_contract() {
  cat "$lock_file"
  printf '%s\n' 'ABIS=arm64-v8a,armeabi-v7a,x86_64'
  printf '%s\n' "${common_flags[@]}"
  printf '%s\n' 'OUTPUT=one replaceable libyl_player_ffmpeg.so per ABI'
  printf '%s\n' 'BRIDGE=android/src/main/cpp/yl_player_ffmpeg.cpp'
}

print_abi_flags() {
  case "$1" in
    arm64-v8a)
      printf '%s\n' '--arch=aarch64'
      ;;
    armeabi-v7a)
      printf '%s\n' '--arch=arm' '--cpu=armv7-a' '--enable-thumb'
      ;;
    x86_64)
      printf '%s\n' '--arch=x86_64' '--disable-x86asm'
      ;;
    *)
      echo "unsupported Android ABI: $1" >&2
      return 2
      ;;
  esac
}

mode=${1:---verify}
case "$mode" in
  --print-contract)
    print_contract
    exit 0
    ;;
  --print-abi-flags)
    [[ $# == 2 ]] || {
      echo 'usage: --print-abi-flags ABI' >&2
      exit 2
    }
    print_abi_flags "$2"
    exit 0
    ;;
  --build-candidate)
    [[ $# == 2 && ! -e $2 ]] || {
      echo 'usage: --build-candidate NEW_DIRECTORY' >&2
      exit 2
    }
    candidate=$2
    ;;
  --link-candidate)
    [[ $# == 3 && -d $2 ]] || {
      echo 'usage: --link-candidate STATIC_INPUT_DIRECTORY OUTPUT_DIRECTORY' >&2
      exit 2
    }
    static_candidate=$2
    linked_output=$3
    ;;
  *)
    echo 'usage: --print-contract | --print-abi-flags ABI | --build-candidate NEW_DIRECTORY | --link-candidate STATIC_INPUT_DIRECTORY OUTPUT_DIRECTORY' >&2
    exit 2
    ;;
esac

android_sdk=${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}
ndk_root="$android_sdk/ndk/$ANDROID_NDK_VERSION"
toolchain="$ndk_root/toolchains/llvm/prebuilt/darwin-x86_64"
if [[ $(uname -m) == arm64 && -d "$ndk_root/toolchains/llvm/prebuilt/darwin-arm64" ]]; then
  toolchain="$ndk_root/toolchains/llvm/prebuilt/darwin-arm64"
fi
[[ -x "$toolchain/bin/clang" ]] || {
  echo "Android NDK $ANDROID_NDK_VERSION not found under $android_sdk" >&2
  exit 1
}

link_candidate() {
  local input=$1
  local output=$2
  local bridge="$package_root/android/src/main/cpp/yl_player_ffmpeg.cpp"
  [[ -f $bridge ]] || { echo "missing JNI bridge: $bridge" >&2; exit 1; }
  mkdir -p "$output"
  for abi in "${abis[@]}"; do
    local triple
    case "$abi" in
      arm64-v8a) triple=aarch64-linux-android ;;
      armeabi-v7a) triple=armv7a-linux-androideabi ;;
      x86_64) triple=x86_64-linux-android ;;
    esac
    local abi_input="$input/$abi"
    local abi_output="$output/$abi"
    [[ -f $abi_input/libavformat.a && -d $abi_input/include ]] || {
      echo "incomplete FFmpeg input for $abi" >&2
      exit 1
    }
    mkdir -p "$abi_output"
    "$toolchain/bin/${triple}${ANDROID_MIN_API}-clang++" \
      -std=c++17 -O2 -fPIC -fvisibility=hidden -shared -static-libstdc++ \
      -Wl,-z,max-page-size=16384 -Wl,--build-id=sha1 \
      -I"$abi_input/include" \
      "$bridge" \
      -Wl,--start-group \
      "$abi_input/libavformat.a" "$abi_input/libavcodec.a" \
      "$abi_input/libswresample.a" "$abi_input/libavutil.a" \
      -Wl,--end-group \
      -landroid -lEGL -lGLESv2 -llog -lz -lm -ldl -latomic \
      -o "$abi_output/libyl_player_ffmpeg.so"
    "$toolchain/bin/llvm-strip" --strip-unneeded "$abi_output/libyl_player_ffmpeg.so"
  done
  cp "$lock_file" "$output/"
  print_contract >"$output/configure-contract.txt"
  echo "replaceable JNI shared libraries ready: $output"
}

if [[ $mode == --link-candidate ]]; then
  link_candidate "$static_candidate" "$linked_output"
  exit 0
fi

work_root=$(mktemp -d "${TMPDIR:-/tmp}/yl-android-ffmpeg.XXXXXX")
cleanup() {
  if [[ ${YL_KEEP_FFMPEG_BUILD:-0} == 1 ]]; then
    echo "kept FFmpeg build directory: $work_root"
  else
    rm -rf "$work_root"
  fi
}
trap cleanup EXIT

archive="$work_root/ffmpeg-$FFMPEG_VERSION.tar.xz"
signature="$archive.asc"
source_root="$work_root/ffmpeg-$FFMPEG_VERSION"
if [[ -n ${YL_FFMPEG_ARCHIVE:-} ]]; then
  cp "$YL_FFMPEG_ARCHIVE" "$archive"
else
  curl --fail --location --retry 3 --output "$archive" "$FFMPEG_URL"
fi
[[ $(shasum -a 256 "$archive" | awk '{print $1}') == "$FFMPEG_SHA256" ]] || {
  echo 'FFmpeg source checksum mismatch' >&2
  exit 1
}
key_file="$script_dir/FFMPEG_RELEASE_KEY.asc"
[[ -f $key_file && $(shasum -a 256 "$key_file" | awk '{print $1}') == "$FFMPEG_SIGNING_KEY_SHA256" ]] || {
  echo 'Pinned FFmpeg signing key is missing or changed' >&2
  exit 1
}
command -v gpg >/dev/null 2>&1 || { echo 'gpg is required for FFmpeg source verification' >&2; exit 1; }
if [[ -n ${YL_FFMPEG_SIGNATURE:-} ]]; then
  cp "$YL_FFMPEG_SIGNATURE" "$signature"
else
  curl --fail --location --retry 3 --output "$signature" "$FFMPEG_SIGNATURE_URL"
fi
gpg_home="$work_root/gnupg"
mkdir -p "$gpg_home"
chmod 700 "$gpg_home"
GNUPGHOME="$gpg_home" gpg --batch --no-autostart --quiet --import "$key_file"
GNUPGHOME="$gpg_home" gpg --batch --no-autostart --status-fd 1 --verify "$signature" "$archive" >"$work_root/signature.status"
grep -F "[GNUPG:] VALIDSIG $FFMPEG_SIGNING_KEY_FINGERPRINT" "$work_root/signature.status" >/dev/null || {
  echo 'FFmpeg source signature fingerprint mismatch' >&2
  exit 1
}
tar -xf "$archive" -C "$work_root"
mkdir -p "$candidate"

build_abi() {
  local abi=$1
  local triple
  local configure_flags
  case "$abi" in
    arm64-v8a)
      triple=aarch64-linux-android
      configure_flags=(--arch=aarch64)
      ;;
    armeabi-v7a)
      triple=armv7a-linux-androideabi
      configure_flags=(--arch=arm --cpu=armv7-a --enable-thumb)
      ;;
    x86_64)
      triple=x86_64-linux-android
      configure_flags=(--arch=x86_64 --disable-x86asm)
      ;;
  esac
  local build_root="$work_root/build/$abi"
  local install_root="$build_root/install"
  mkdir -p "$build_root"
  (
    cd "$build_root"
    "$source_root/configure" \
      --prefix="$install_root" \
      --target-os=android \
      --enable-cross-compile \
      --cc="$toolchain/bin/${triple}${ANDROID_MIN_API}-clang" \
      --cxx="$toolchain/bin/${triple}${ANDROID_MIN_API}-clang++" \
      --ar="$toolchain/bin/llvm-ar" \
      --ranlib="$toolchain/bin/llvm-ranlib" \
      --strip="$toolchain/bin/llvm-strip" \
      --extra-cflags="-fPIC -fvisibility=hidden -ffile-prefix-map=$source_root=/yl_ffmpeg/src" \
      --extra-ldflags="-Wl,-z,max-page-size=16384" \
      "${configure_flags[@]}" \
      "${common_flags[@]}"
    make -j"${YL_FFMPEG_JOBS:-4}"
    make install
  )
  mkdir -p "$candidate/$abi"
  cp "$install_root/lib/libavformat.a" "$candidate/$abi/"
  cp "$install_root/lib/libavcodec.a" "$candidate/$abi/"
  cp "$install_root/lib/libavutil.a" "$candidate/$abi/"
  cp "$install_root/lib/libswresample.a" "$candidate/$abi/"
  cp -R "$install_root/include" "$candidate/$abi/"
}

for abi in "${abis[@]}"; do
  build_abi "$abi"
done
cp "$lock_file" "$candidate/"
print_contract >"$candidate/configure-contract.txt"
echo "FFmpeg static inputs ready for the replaceable JNI shared library: $candidate"
