#!/bin/sh
# Собирает дерево файлов пакета (будущий data.tar.gz).
#
# usage: stage.sh <upstream-srcdir> <binaries-dir> <entware-arch> <outroot>
set -e
. "$(dirname "$0")/lib.sh"

SRC=$1
BIN=$2
ARCH=$3
OUT=$4
if [ -z "$SRC" ] || [ -z "$BIN" ] || [ -z "$ARCH" ] || [ -z "$OUT" ]; then
	die "usage: stage.sh <srcdir> <bindir> <arch> <outroot>"
fi
arch_check "$ARCH"
[ -d "$SRC/common" ] || die "$SRC не похож на дерево zapret2"

HERE=$(cd "$(dirname "$0")/.." && pwd)
INCLUDE_BLOCKCHECK=${INCLUDE_BLOCKCHECK:-1}

msg "собираю дерево пакета в $OUT"
rm -rf "$OUT"
mkdir -p "$OUT$ZAPRET_BASE"

# 1. Наши файлы: init-скрипт, хук ndm, конфиг, обёртки в /opt/bin
cp -a "$HERE/package/root/." "$OUT/"

# Скрипты установки и отката едут на роутер вместе с пакетом. Для отката это
# принципиально: если zapret2 положит интернет, скачать uninstall.sh через curl
# будет уже нечем, а откатываться надо именно тогда.
# Живут они в корне репозитория (оттуда их качают через raw.githubusercontent),
# сюда копируются при сборке — чтобы не держать две расходящиеся копии.
cp -a "$HERE/install.sh"   "$OUT/opt/bin/zapret2-install"
cp -a "$HERE/uninstall.sh" "$OUT/opt/bin/zapret2-uninstall"

# 2. Runtime-часть upstream. Исходники (nfq2/*.c, mdig, ip2net), docs и Makefile
#    в пакет не кладём — на роутере они бесполезны.
for d in common ipset lua files; do
	[ -d "$SRC/$d" ] || die "нет $SRC/$d"
	cp -a "$SRC/$d" "$OUT$ZAPRET_BASE/"
done
mkdir -p "$OUT$ZAPRET_BASE/init.d/sysv"
cp -a "$SRC/init.d/sysv/functions" "$OUT$ZAPRET_BASE/init.d/sysv/functions"
cp -a "$SRC/config.default" "$OUT$ZAPRET_BASE/config.default"

# Пакет несёт код upstream, а он под MIT — уведомление об авторстве обязано
# ехать вместе с ним.
if [ -f "$SRC/docs/LICENSE.txt" ]; then
	cp -a "$SRC/docs/LICENSE.txt" "$OUT$ZAPRET_BASE/LICENSE.upstream.txt"
else
	warn "в дереве upstream нет docs/LICENSE.txt — пакет уедет без уведомления об авторстве"
fi
cp -a "$HERE/LICENSE" "$OUT$ZAPRET_BASE/LICENSE.packaging.txt"

# blockcheck2 нужен, чтобы подобрать стратегию прямо на роутере
if [ "$INCLUDE_BLOCKCHECK" = 1 ] && [ -f "$SRC/blockcheck2.sh" ]; then
	cp -a "$SRC/blockcheck2.sh" "$OUT$ZAPRET_BASE/blockcheck2.sh"
	[ -d "$SRC/blockcheck2.d" ] && cp -a "$SRC/blockcheck2.d" "$OUT$ZAPRET_BASE/"
fi

# ipset/*.default в пакете не нужны: пользовательские списки лежат в $ZAPRET_RW/ipset
rm -f "$OUT$ZAPRET_BASE/ipset/"*.default

# 3. Бинарники по путям, которые ждут init-скрипты zapret2
for f in nfqws2:nfq2 mdig:mdig ip2net:ip2net; do
	exe=${f%%:*}; dir=${f##*:}
	[ -f "$BIN/$exe" ] || die "нет бинарника $BIN/$exe"
	mkdir -p "$OUT$ZAPRET_BASE/$dir"
	cp "$BIN/$exe" "$OUT$ZAPRET_BASE/$dir/$exe"
done

# 4. Права
find "$OUT" -type d -exec chmod 755 {} +
find "$OUT" -type f -exec chmod 644 {} +
chmod 755 "$OUT$ZAPRET_BASE/nfq2/nfqws2" "$OUT$ZAPRET_BASE/mdig/mdig" "$OUT$ZAPRET_BASE/ip2net/ip2net"
chmod 755 "$OUT/opt/etc/init.d/S99zapret2" "$OUT/opt/etc/ndm/netfilter.d/50-zapret2.sh"
chmod 755 "$OUT/opt/bin/zapret2" "$OUT/opt/bin/zapret2-list" \
          "$OUT/opt/bin/zapret2-install" "$OUT/opt/bin/zapret2-uninstall"
find "$OUT$ZAPRET_BASE/ipset" -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true
if [ -f "$OUT$ZAPRET_BASE/blockcheck2.sh" ]; then
	chmod 755 "$OUT$ZAPRET_BASE/blockcheck2.sh"
	find "$OUT$ZAPRET_BASE/blockcheck2.d" -type f -exec chmod 755 {} + 2>/dev/null || true
fi

msg "дерево готово, $(du -sh "$OUT" | cut -f1)"
