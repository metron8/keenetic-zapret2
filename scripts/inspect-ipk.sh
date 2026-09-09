#!/bin/sh
# Проверка собранного .ipk без роутера: структура, control, права, ELF-архитектура.
#
# usage: inspect-ipk.sh <file.ipk> [entware-arch]
set -e
. "$(dirname "$0")/lib.sh"

IPK=$1
WANT_ARCH=$2
[ -n "$IPK" ] || die "usage: inspect-ipk.sh <file.ipk> [arch]"
[ -f "$IPK" ] || die "нет файла $IPK"
IPK=$(cd "$(dirname "$IPK")" && pwd)/$(basename "$IPK")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
rc=0
fail() { echo "СБОЙ: $*" >&2; rc=1; }
ok()   { echo "ok   $*"; }

tar -C "$TMP" -xzf "$IPK" || die "внешний архив не распаковался (ожидается gzip-tar формата ipkg)"

for f in debian-binary control.tar.gz data.tar.gz; do
	[ -f "$TMP/$f" ] && ok "$f на месте" || fail "во внешнем архиве нет $f"
done
[ "$(cat "$TMP/debian-binary" 2>/dev/null)" = "2.0" ] && ok "debian-binary = 2.0" || fail "debian-binary не 2.0"

mkdir -p "$TMP/c" "$TMP/d"
tar -C "$TMP/c" -xzf "$TMP/control.tar.gz"
tar -C "$TMP/d" -xzf "$TMP/data.tar.gz"

echo "--- control ---"
cat "$TMP/c/control"
for k in Package Version Architecture Description; do
	grep -q "^$k:" "$TMP/c/control" && ok "поле $k есть" || fail "в control нет поля $k"
done
if [ -n "$WANT_ARCH" ]; then
	grep -q "^Architecture: $WANT_ARCH$" "$TMP/c/control" && ok "Architecture = $WANT_ARCH" ||
		fail "Architecture в control не равен $WANT_ARCH"
fi

echo "--- maintainer-скрипты ---"
for f in postinst prerm postrm; do
	if [ -f "$TMP/c/$f" ]; then
		[ -x "$TMP/c/$f" ] && ok "$f исполняемый" || fail "$f не исполняемый"
		sh -n "$TMP/c/$f" && ok "$f синтаксически корректен" || fail "$f не парсится"
	fi
done
if [ -f "$TMP/c/conffiles" ]; then
	while IFS= read -r cf; do
		[ -n "$cf" ] || continue
		[ -f "$TMP/d/.$cf" ] && ok "conffile $cf есть в data" || fail "conffile $cf объявлен, но его нет в data"
	done <"$TMP/c/conffiles"
fi

echo "--- содержимое ---"
for f in ./opt/etc/init.d/S99zapret2 ./opt/etc/ndm/netfilter.d/50-zapret2.sh \
         ./opt/bin/zapret2 ./opt/zapret2/nfq2/nfqws2 ./opt/zapret2/mdig/mdig \
         ./opt/zapret2/ip2net/ip2net ./opt/zapret2/init.d/sysv/functions \
         ./opt/zapret2/common/base.sh ./opt/etc/zapret2/config; do
	if [ -f "$TMP/d/$f" ]; then ok "$f"; else fail "нет $f"; fi
done
for f in ./opt/etc/init.d/S99zapret2 ./opt/etc/ndm/netfilter.d/50-zapret2.sh ./opt/bin/zapret2 \
         ./opt/zapret2/nfq2/nfqws2 ./opt/zapret2/mdig/mdig ./opt/zapret2/ip2net/ip2net; do
	[ -x "$TMP/d/$f" ] && ok "$f исполняемый" || fail "$f не исполняемый"
done
sh -n "$TMP/d/./opt/etc/init.d/S99zapret2" && ok "init-скрипт парсится" || fail "init-скрипт не парсится"
sh -n "$TMP/d/./opt/etc/zapret2/config" && ok "config парсится как shell" || fail "config не парсится"

# в data не должно быть исходников и хлама
for junk in ./opt/zapret2/nfq2/nfqws.c ./opt/zapret2/Makefile ./opt/zapret2/docs ./opt/zapret2/.git; do
	[ -e "$TMP/d/$junk" ] && fail "в пакет попал лишний $junk" || ok "нет лишнего $junk"
done

echo "--- архитектура бинарников ---"
if [ -n "$WANT_ARCH" ]; then
	set -- $(arch_elf "$WANT_ARCH")
	want_class=$1; want_data=$2; want_machine=$3
	for exe in nfq2/nfqws2 mdig/mdig ip2net/ip2net; do
		f="$TMP/d/./opt/zapret2/$exe"
		[ -f "$f" ] || continue
		magic=$(od -An -tx1 -N4 "$f" | tr -d ' \n')
		if [ "$magic" != "7f454c46" ]; then
			fail "$exe не ELF (magic=$magic) — для Keenetic это всегда ошибка"
			continue
		fi
		cls=$(elf_byte "$f" 4); dat=$(elf_byte "$f" 5); mach=$(elf_machine "$f")
		if [ "$cls" = "$want_class" ] && [ "$dat" = "$want_data" ] && [ "$mach" = "$want_machine" ]; then
			ok "$exe: ELF class=$cls data=$dat machine=$mach — соответствует $WANT_ARCH"
		else
			fail "$exe: ELF class=$cls data=$dat machine=$mach, а для $WANT_ARCH ожидается $want_class/$want_data/$want_machine"
		fi
	done
else
	echo "(архитектура не передана вторым аргументом — проверка ELF пропущена)"
fi
if command -v file >/dev/null 2>&1; then
	file "$TMP/d/./opt/zapret2/nfq2/nfqws2" "$TMP/d/./opt/zapret2/mdig/mdig" "$TMP/d/./opt/zapret2/ip2net/ip2net"
fi

echo
[ "$rc" = 0 ] && echo "ИТОГ: пакет выглядит корректно" || echo "ИТОГ: есть проблемы (см. СБОЙ выше)"
exit $rc
