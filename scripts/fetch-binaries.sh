#!/bin/sh
# Скачивает готовые статические бинарники nfqws2/mdig/ip2net из релиза zapret2
# и проверяет их по sha256sum.txt из того же релиза.
#
# usage: fetch-binaries.sh <ref> <entware-arch> <destdir>
set -e
. "$(dirname "$0")/lib.sh"

REF=$1
ARCH=$2
DEST=$3
[ -n "$REF" ] && [ -n "$ARCH" ] && [ -n "$DEST" ] || die "usage: fetch-binaries.sh <ref> <arch> <destdir>"
arch_check "$ARCH"

need tar sha256sum
if command -v curl >/dev/null 2>&1; then DL="curl -fsSL -o"
elif command -v wget >/dev/null 2>&1; then DL="wget -qO"
else die "нужен curl или wget"; fi

BINDIR=$(arch_bindir "$ARCH")
TARBALL="$PKG_NAME-$REF.tar.gz"
BASEURL="$UPSTREAM_REPO/releases/download/$REF"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

msg "качаю $BASEURL/$TARBALL"
$DL "$TMP/$TARBALL" "$BASEURL/$TARBALL" ||
	die "не скачался релизный тарбол. Проверь, что тег '$REF' существует и есть выход в сеть,
     либо собери бинарники из исходников: make ipk BINSRC=source"

msg "качаю $BASEURL/sha256sum.txt"
$DL "$TMP/sha256sum.txt" "$BASEURL/sha256sum.txt" || warn "sha256sum.txt недоступен — проверка контрольных сумм пропущена"

msg "распаковываю binaries/$BINDIR"
tar -C "$TMP" -xzf "$TMP/$TARBALL" "$PKG_NAME-$REF/binaries/$BINDIR" ||
	die "в релизе нет binaries/$BINDIR — для арки $ARCH готовых бинарников не публикуют"

SRC="$TMP/$PKG_NAME-$REF/binaries/$BINDIR"

if [ -f "$TMP/sha256sum.txt" ]; then
	msg "сверяю контрольные суммы"
	( cd "$TMP" && grep "$PKG_NAME-$REF/binaries/$BINDIR/" sha256sum.txt >want.txt || true )
	[ -s "$TMP/want.txt" ] || die "в sha256sum.txt нет записей для binaries/$BINDIR"
	( cd "$TMP" && sha256sum -c want.txt ) || die "контрольные суммы бинарников не сошлись"
fi

mkdir -p "$DEST"
rm -f "$DEST"/*
for f in nfqws2 mdig ip2net; do
	[ -f "$SRC/$f" ] || die "в релизе нет $BINDIR/$f"
	cp "$SRC/$f" "$DEST/$f"
	chmod 755 "$DEST/$f"
done

msg "бинарники ($ARCH -> $BINDIR) сложены в $DEST"
ls -l "$DEST" >&2
