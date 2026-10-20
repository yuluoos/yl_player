#!/bin/sh
# Test-only Xiph reference tools; these libraries never enter the product.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$#" = 1 ] && [ ! -e "$1" ] || { echo 'usage: build_vorbis_reference.sh NEW_ABSOLUTE_DIRECTORY' >&2; exit 2; }
case "$1" in /*) ;; *) exit 2 ;; esac
root=$1
mkdir -p "$root/src" "$root/install"
fetch() {
 name=$1 url=$2 digest=$3
 curl --fail --location --retry 3 "$url" -o "$root/src/$name"
 [ "$(shasum -a 256 "$root/src/$name" | awk '{print $1}')" = "$digest" ] || exit 1
 tar -xf "$root/src/$name" -C "$root/src"
}
fetch libogg-1.3.6.tar.xz https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz 5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061
fetch libvorbis-1.3.7.tar.xz https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b
(cd "$root/src/libogg-1.3.6"; ./configure --prefix="$root/install" --disable-shared --enable-static --disable-docs; make -j4 CFLAGS=-O2; make install CFLAGS=-O2)
(cd "$root/src/libvorbis-1.3.7"; CFLAGS="-O2" PKG_CONFIG_PATH="$root/install/lib/pkgconfig" ./configure --prefix="$root/install" --disable-shared --enable-static --disable-docs; make -j4 CFLAGS=-O2; make install CFLAGS=-O2)
mkdir -p "$root/install/bin"
xcrun clang -O2 -I"$root/install/include" "$script_dir/vorbis_reference_encoder.c" \
 "$root/install/lib/libvorbisenc.a" "$root/install/lib/libvorbis.a" "$root/install/lib/libogg.a" \
 -o "$root/install/bin/yl_vorbis_encoder"
printf 'Test-only reference prefix: %s/install\n' "$root"
