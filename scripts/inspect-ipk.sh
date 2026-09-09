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
	if [ -f "$TMP/$f" ]; then ok "$f на месте"; else fail "во внешнем архиве нет $f"; fi
done
if [ "$(cat "$TMP/debian-binary" 2>/dev/null)" = "2.0" ]; then
	ok "debian-binary = 2.0"
else
	fail "debian-binary не 2.0"
fi

mkdir -p "$TMP/c" "$TMP/d"
tar -C "$TMP/c" -xzf "$TMP/control.tar.gz"
tar -C "$TMP/d" -xzf "$TMP/data.tar.gz"

echo "--- control ---"
cat "$TMP/c/control"
for k in Package Version Architecture Description; do
	if grep -q "^$k:" "$TMP/c/control"; then ok "поле $k есть"; else fail "в control нет поля $k"; fi
done
if [ -n "$WANT_ARCH" ]; then
	if grep -q "^Architecture: $WANT_ARCH$" "$TMP/c/control"; then
		ok "Architecture = $WANT_ARCH"
	else
		fail "Architecture в control не равен $WANT_ARCH"
	fi
fi

echo "--- maintainer-скрипты ---"
for f in postinst prerm postrm; do
	if [ -f "$TMP/c/$f" ]; then
		if [ -x "$TMP/c/$f" ]; then ok "$f исполняемый"; else fail "$f не исполняемый"; fi
		if sh -n "$TMP/c/$f"; then ok "$f синтаксически корректен"; else fail "$f не парсится"; fi
	fi
done
if [ -f "$TMP/c/conffiles" ]; then
	while IFS= read -r cf; do
		[ -n "$cf" ] || continue
		if [ -f "$TMP/d/.$cf" ]; then
			ok "conffile $cf есть в data"
		else
			fail "conffile $cf объявлен, но его нет в data"
		fi
	done <"$TMP/c/conffiles"
fi

echo "--- содержимое ---"
for f in ./opt/etc/init.d/S99zapret2 ./opt/etc/ndm/netfilter.d/50-zapret2.sh \
         ./opt/bin/zapret2 ./opt/bin/zapret2-list \
         ./opt/bin/zapret2-install ./opt/bin/zapret2-uninstall \
         ./opt/zapret2/nfq2/nfqws2 ./opt/zapret2/mdig/mdig \
         ./opt/zapret2/ip2net/ip2net ./opt/zapret2/init.d/sysv/functions \
         ./opt/zapret2/common/base.sh ./opt/etc/zapret2/config; do
	if [ -f "$TMP/d/$f" ]; then ok "$f"; else fail "нет $f"; fi
done
for f in ./opt/etc/init.d/S99zapret2 ./opt/etc/ndm/netfilter.d/50-zapret2.sh \
         ./opt/bin/zapret2 ./opt/bin/zapret2-list \
         ./opt/bin/zapret2-install ./opt/bin/zapret2-uninstall \
         ./opt/zapret2/nfq2/nfqws2 ./opt/zapret2/mdig/mdig ./opt/zapret2/ip2net/ip2net; do
	if [ -x "$TMP/d/$f" ]; then ok "$f исполняемый"; else fail "$f не исполняемый"; fi
done
if sh -n "$TMP/d/./opt/etc/init.d/S99zapret2"; then ok "init-скрипт парсится"; else fail "init-скрипт не парсится"; fi
if sh -n "$TMP/d/./opt/etc/zapret2/config"; then ok "config парсится как shell"; else fail "config не парсится"; fi

# в data не должно быть исходников и хлама
for junk in ./opt/zapret2/nfq2/nfqws.c ./opt/zapret2/Makefile ./opt/zapret2/docs ./opt/zapret2/.git; do
	if [ -e "$TMP/d/$junk" ]; then fail "в пакет попал лишний $junk"; else ok "нет лишнего $junk"; fi
done

echo "--- архитектура бинарников ---"
if [ -n "$WANT_ARCH" ]; then
	# arch_elf печатает три поля через пробел — разбиение на слова здесь нужное
	# shellcheck disable=SC2046
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
if [ "$rc" = 0 ]; then
	echo "ИТОГ: пакет выглядит корректно"
else
	echo "ИТОГ: есть проблемы (см. СБОЙ выше)"
fi
exit $rc
