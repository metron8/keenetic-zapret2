#!/bin/sh
# Кросс-сборка nfqws2/mdig/ip2net из исходников zapret2 под Entware-архитектуру.
# Повторяет шаги .github/workflows/build.yml upstream: musl-cross тулчейн,
# статические luajit2 / libmnl / libnfnetlink / libnetfilter_queue / zlib.
#
# usage: build-binaries.sh <srcdir> <entware-arch> <destdir>
#
# Требуется на сборочной машине: gcc (+ gcc-multilib для 32-битных целей),
# make, patch, tar, xz, bzip2, curl|wget, pkg-config.
set -e
. "$(dirname "$0")/lib.sh"

SRC=$1
ARCH=$2
DEST=$3
[ -n "$SRC" ] && [ -n "$ARCH" ] && [ -n "$DEST" ] || die "usage: build-binaries.sh <srcdir> <arch> <destdir>"
arch_check "$ARCH"
[ -d "$SRC/nfq2" ] || die "$SRC не похож на дерево zapret2 (нет nfq2/)"

# версии зависимостей — те же, что в CI upstream
LUAJIT_RELEASE=${LUAJIT_RELEASE:-2.1-20250826}
LUAJIT_VER=2.1
LUAJIT_LUAVER=5.1
LIBMNL_VER=${LIBMNL_VER:-1.0.5}
LIBNFNETLINK_VER=${LIBNFNETLINK_VER:-1.0.2}
LIBNFQ_VER=${LIBNFQ_VER:-1.0.5}
ZLIB_VER=${ZLIB_VER:-1.3.1}

need make gcc tar patch
if command -v curl >/dev/null 2>&1; then FETCH="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then FETCH="wget -qO-"
else die "нужен curl или wget"; fi

TARGET=$(arch_toolchain "$ARCH")
CPU=$(arch_cpuflags "$ARCH")
SYSMALLOC=$(arch_luajit_sysmalloc "$ARCH")

WORK=${BUILD_WORK:-$(pwd)/build/xbuild/$ARCH}
TOOLS="$WORK/tools"
DEPS="$WORK/deps"
mkdir -p "$TOOLS" "$DEPS" "$WORK/src"

# --- тулчейн ------------------------------------------------------------------

if [ ! -x "$TOOLS/$TARGET/bin/$TARGET-gcc" ]; then
	msg "качаю тулчейн $TARGET"
	$FETCH "$MUSL_CROSS_REPO/releases/download/latest/$TARGET.tar.xz" | tar -C "$TOOLS" -xJ ||
		die "не удалось получить тулчейн $TARGET из $MUSL_CROSS_REPO"
fi
PATH="$TOOLS/$TARGET/bin:$PATH"
export PATH
command -v "$TARGET-gcc" >/dev/null 2>&1 || die "$TARGET-gcc не найден после распаковки тулчейна"

CC="$TARGET-gcc";  export CC
AR="$TARGET-ar";   export AR
LD="$TARGET-ld";   export LD
NM="$TARGET-nm";   export NM
STRIP="$TARGET-strip"; export STRIP
PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"; export PKG_CONFIG_PATH

OPTIMIZE=-Oz
MINSIZE="$OPTIMIZE -flto=auto -ffunction-sections -fdata-sections"
LDMINSIZE="-Wl,--gc-sections -flto=auto"

# --- luajit2 ------------------------------------------------------------------

if [ ! -f "$DEPS/lib/libluajit-$LUAJIT_LUAVER.a" ]; then
	msg "собираю luajit2 $LUAJIT_RELEASE"
	rm -rf "$WORK/src/luajit2"
	mkdir -p "$WORK/src/luajit2"
	$FETCH "https://github.com/openresty/luajit2/archive/refs/tags/v$LUAJIT_RELEASE.tar.gz" |
		tar -C "$WORK/src/luajit2" --strip-components=1 -xz
	# buildvm luajit исполняется на хосте и должен быть той же разрядности, что цель
	case "$ARCH" in
		aarch64-*) HOSTCC="cc" ;;
		*)         HOSTCC="cc -m32" ;;
	esac
	( cd "$WORK/src/luajit2" &&
	  make BUILDMODE=static XCFLAGS="$SYSMALLOC -DLUAJIT_DISABLE_FFI" \
	       HOST_CC="$HOSTCC" CROSS= CC="$CC" TARGET_AR="$AR rcus" TARGET_STRIP="$STRIP" \
	       TARGET_CFLAGS="$CPU $MINSIZE" TARGET_LDFLAGS="$CPU $LDMINSIZE" -j"$(nproc)" &&
	  make install PREFIX= DESTDIR="$DEPS" ) ||
		die "luajit2 не собрался (для 32-битных целей нужен gcc-multilib на хосте)"
fi
LCFLAGS="-I$DEPS/include/luajit-$LUAJIT_VER"
LLIB="-L$DEPS/lib -lluajit-$LUAJIT_LUAVER"

# --- netfilter-библиотеки -----------------------------------------------------

build_autotools_dep()
{
	# $1 - имя, $2 - версия, $3 - url
	local name=$1 ver=$2 url=$3
	if [ -f "$DEPS/lib/pkgconfig/$name.pc" ]; then
		msg "$name уже собран, пропускаю"
		return 0
	fi
	msg "собираю $name $ver"
	rm -rf "$WORK/src/$name"
	mkdir -p "$WORK/src/$name"
	$FETCH "$url" | tar -C "$WORK/src/$name" --strip-components=1 -xj
	( cd "$WORK/src/$name" &&
	  CFLAGS="$CPU $MINSIZE" LDFLAGS="$LDMINSIZE" \
	  ./configure --prefix= --host="$TARGET" --enable-static --disable-shared --disable-dependency-tracking &&
	  make install -j"$(nproc)" DESTDIR="$DEPS" ) || die "$name не собрался"
	# в .pc остаётся prefix= из configure — правим, иначе pkg-config отдаст пустые пути
	sed -i "s|^prefix=.*|prefix=$DEPS|" "$DEPS/lib/pkgconfig/$name.pc"
}

build_autotools_dep libmnl "$LIBMNL_VER" \
	"https://www.netfilter.org/pub/libmnl/libmnl-$LIBMNL_VER.tar.bz2"
build_autotools_dep libnfnetlink "$LIBNFNETLINK_VER" \
	"https://www.netfilter.org/pub/libnfnetlink/libnfnetlink-$LIBNFNETLINK_VER.tar.bz2"
build_autotools_dep libnetfilter_queue "$LIBNFQ_VER" \
	"https://www.netfilter.org/pub/libnetfilter_queue/libnetfilter_queue-$LIBNFQ_VER.tar.bz2"

# --- zlib ---------------------------------------------------------------------

if [ ! -f "$DEPS/lib/libz.a" ]; then
	msg "собираю zlib $ZLIB_VER"
	rm -rf "$WORK/src/zlib"
	mkdir -p "$WORK/src/zlib"
	$FETCH "https://github.com/madler/zlib/archive/refs/tags/v$ZLIB_VER.tar.gz" |
		tar -C "$WORK/src/zlib" --strip-components=1 -xz
	( cd "$WORK/src/zlib" &&
	  CFLAGS="$CPU $MINSIZE" ./configure --prefix= --static &&
	  make install -j"$(nproc)" DESTDIR="$DEPS" ) || die "zlib не собрался"
fi

# --- заголовки, которых нет в musl -------------------------------------------

mkdir -p "$DEPS/include/sys"
for h in queue.h capability.h; do
	[ -f "$DEPS/include/sys/$h" ] && continue
	found=
	for cand in "/usr/include/sys/$h" "/usr/include/$(uname -m)-linux-gnu/sys/$h"; do
		[ -f "$cand" ] && { cp "$cand" "$DEPS/include/sys/$h"; found=1; break; }
	done
	[ -n "$found" ] && continue
	case "$h" in
		queue.h)      $FETCH "https://git.alpinelinux.org/aports/plain/main/bsd-compat-headers/queue.h" >"$DEPS/include/sys/queue.h" ;;
		capability.h) $FETCH "https://git.kernel.org/pub/scm/libs/libcap/libcap.git/plain/libcap/include/sys/capability.h" >"$DEPS/include/sys/capability.h" ;;
	esac
	[ -s "$DEPS/include/sys/$h" ] || die "не нашёл sys/$h (поставь libcap-dev на хосте)"
done

# --- собственно zapret2 -------------------------------------------------------

msg "собираю nfqws2/mdig/ip2net под $ARCH ($TARGET)"
GH_HASH=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)
GH_VER=$(git -C "$SRC" describe --tags --always 2>/dev/null || echo unknown)

make -C "$SRC" clean >/dev/null 2>&1 || true
OPTIMIZE="$OPTIMIZE" \
CFLAGS="-DZAPRET_GH_VER=$GH_VER -DZAPRET_GH_HASH=$GH_HASH -static-libgcc -I$DEPS/include $CPU" \
LDFLAGS="-L$DEPS/lib" \
make -C "$SRC" CFLAGS_PIC= LDFLAGS_PIE=-static LUA_JIT=1 \
	LUA_CFLAGS="$LCFLAGS" LUA_LIB="$LLIB" -j"$(nproc)" || die "сборка zapret2 не удалась"

mkdir -p "$DEST"
rm -f "$DEST"/*
for f in nfqws2 mdig ip2net; do
	[ -f "$SRC/binaries/my/$f" ] || die "после сборки нет $SRC/binaries/my/$f"
	cp "$SRC/binaries/my/$f" "$DEST/$f"
	chmod 755 "$DEST/$f"
done

msg "бинарники собраны в $DEST"
ls -l "$DEST" >&2
