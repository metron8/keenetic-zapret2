#!/bin/sh
# Пакует подготовленное дерево в .ipk (формат ipkg: gzip-tar с debian-binary,
# control.tar.gz и data.tar.gz внутри — именно его понимает opkg в Entware).
#
# usage: mkipk.sh <dataroot> <entware-arch> <upstream-ref> <outfile>
set -e
. "$(dirname "$0")/lib.sh"

ROOT=$1
ARCH=$2
REF=$3
OUTFILE=$4
[ -n "$ROOT" ] && [ -n "$ARCH" ] && [ -n "$REF" ] && [ -n "$OUTFILE" ] ||
	die "usage: mkipk.sh <dataroot> <arch> <ref> <outfile>"
arch_check "$ARCH"
[ -d "$ROOT/opt" ] || die "$ROOT не похож на дерево пакета (нет opt/)"

need tar gzip
HERE=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(pkg_version "$REF")
# Жёстких зависимостей нет: бинарники статические, а iptables/ipset и модули ядра
# даёт прошивка Keenetic, а не Entware. Что именно не хватает — скажет `zapret2 check`.
DEPENDS=${PKG_DEPENDS:-}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- control ------------------------------------------------------------------

mkdir -p "$TMP/control"
INSTALLED_SIZE=$(du -sb "$ROOT" 2>/dev/null | cut -f1 || true)
[ -n "$INSTALLED_SIZE" ] || INSTALLED_SIZE=$(($(du -sk "$ROOT" | cut -f1) * 1024))

sed -e "s|@PKG_NAME@|$PKG_NAME|g" \
    -e "s|@PKG_VERSION@|$VERSION|g" \
    -e "s|@PKG_ARCH@|$ARCH|g" \
    -e "s|@PKG_DEPENDS@|$DEPENDS|g" \
    -e "s|@PKG_SECTION@|$PKG_SECTION|g" \
    -e "s|@PKG_PRIORITY@|$PKG_PRIORITY|g" \
    -e "s|@PKG_MAINTAINER@|$PKG_MAINTAINER|g" \
    -e "s|@PKG_HOMEPAGE@|$PKG_HOMEPAGE|g" \
    "$HERE/package/control/control.tmpl" >"$TMP/control/control"
echo "Installed-Size: $INSTALLED_SIZE" >>"$TMP/control/control"

for f in conffiles postinst prerm postrm; do
	[ -f "$HERE/package/control/$f" ] || continue
	cp "$HERE/package/control/$f" "$TMP/control/$f"
done
chmod 644 "$TMP/control/control" "$TMP/control/conffiles" 2>/dev/null || true
for f in postinst prerm postrm; do
	if [ -f "$TMP/control/$f" ]; then chmod 755 "$TMP/control/$f"; fi
done

# --- сборка архивов -----------------------------------------------------------

# SOURCE_DATE_EPOCH делает сборку воспроизводимой
SDE=${SOURCE_DATE_EPOCH:-$(git -C "$HERE" log -1 --format=%ct 2>/dev/null || echo 0)}
TAROPT="--owner=0 --group=0 --numeric-owner --format=gnu"
if tar --help 2>&1 | grep -q -- --mtime; then
	TAROPT="$TAROPT --mtime=@$SDE"
fi

( cd "$TMP/control" && tar $TAROPT -czf "$TMP/control.tar.gz" ./* )
( cd "$ROOT"        && tar $TAROPT -czf "$TMP/data.tar.gz" ./* )
echo "2.0" >"$TMP/debian-binary"

mkdir -p "$(dirname "$OUTFILE")"
OUTFILE=$(cd "$(dirname "$OUTFILE")" && pwd)/$(basename "$OUTFILE")
( cd "$TMP" && tar $TAROPT -czf "$OUTFILE" ./debian-binary ./data.tar.gz ./control.tar.gz )

msg "готово: $OUTFILE ($(du -h "$OUTFILE" | cut -f1))"
