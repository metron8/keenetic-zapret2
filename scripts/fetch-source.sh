#!/bin/sh
# Забирает дерево zapret2 нужной версии (shell-скрипты, lua, files/fake).
# Бинарники сюда не входят — они приезжают через fetch-binaries.sh либо build-binaries.sh.
#
# usage: fetch-source.sh <ref> <destdir>
set -e
. "$(dirname "$0")/lib.sh"

REF=$1
DEST=$2
if [ -z "$REF" ] || [ -z "$DEST" ]; then
	die "usage: fetch-source.sh <ref> <destdir>"
fi

need git

if [ -d "$DEST/.git" ]; then
	got=$(git -C "$DEST" describe --tags --always 2>/dev/null || echo "")
	msg "исходники уже есть в $DEST ($got), пропускаю"
	exit 0
fi

msg "клонирую $UPSTREAM_REPO @ $REF -> $DEST"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
git clone --depth 1 --branch "$REF" "$UPSTREAM_REPO" "$DEST" >/dev/null 2>&1 ||
	die "не удалось склонировать $UPSTREAM_REPO ref=$REF"

msg "готово: $(git -C "$DEST" rev-parse --short HEAD)"
