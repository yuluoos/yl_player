#!/bin/sh
# Private build helper: called with SDK/architecture and a fresh slice directory.
set -eu
source_root=$1
slice=$2
sdk=$3
arch=$4
minimum=$5
sdk_root=$(xcrun --sdk "$sdk" --show-sdk-path)
clang=$(xcrun --sdk "$sdk" --find clang)
ar=$(xcrun --sdk "$sdk" --find ar)
family=$arch
asm=true
if [ "$arch" = arm64 ]; then family=aarch64; else asm=false; fi
mkdir -p "$slice"
python3 - "$slice/dav1d-cross.ini" "$clang" "$ar" "$sdk_root" "$arch" "$family" "$minimum" "$source_root" <<'PY'
import pathlib,sys
out,clang,ar,sdk,arch,family,minimum,source=sys.argv[1:]
flags=['-arch',arch,'-isysroot',sdk,minimum,'-g0','-fvisibility=hidden',
       '-ffile-prefix-map='+source+'=/yl_dav1d/src','-fdebug-compilation-dir=/yl_dav1d/build']
def value(x): return repr(x)
pathlib.Path(out).write_text('[binaries]\nc = '+value(clang)+'\nar = '+value(ar)+
 '\nstrip = \'strip\'\n[host_machine]\nsystem = \'darwin\'\ncpu_family = '+value(family)+
 '\ncpu = '+value(arch)+'\nendian = \'little\'\n[built-in options]\nc_args = '+value(flags)+
 '\nc_link_args = '+value(['-arch',arch,'-isysroot',sdk,minimum])+'\n')
PY
meson setup "$slice/dav1d-build" "$source_root" --cross-file "$slice/dav1d-cross.ini" \
 --prefix=/yl_dav1d/install --libdir=lib --buildtype=release --default-library=static \
 -Db_staticpic=true -Denable_asm="$asm" -Denable_tools=false -Denable_tests=false \
 -Denable_examples=false -Denable_docs=false
ninja -C "$slice/dav1d-build" -j"${YL_FFMPEG_JOBS:-4}"
DESTDIR="$slice/dav1d-stage" ninja -C "$slice/dav1d-build" install
