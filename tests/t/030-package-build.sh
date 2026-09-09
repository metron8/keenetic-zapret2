#!/bin/sh
# Офлайн-сборка .ipk из синтетического дерева upstream и проверка результата.
# Никакой сети: дерево и «бинарники» генерим фикстурами.
. "$(dirname "$0")/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

make_fake_upstream "$TMP/src"

for arch in mipsel-3.4 aarch64-3.10; do
	echo "    -- $arch"
	bin="$TMP/bin-$arch"; mkdir -p "$bin"
	for f in nfqws2 mdig ip2net; do make_stub_elf "$arch" "$bin/$f"; done

	# фикстура должна быть валидной: сверяем её же нашим парсером ELF
	# shellcheck disable=SC1091
	. "$ROOT/scripts/lib.sh"
	# arch_elf печатает три поля через пробел — разбиение на слова здесь нужное
	# shellcheck disable=SC2046
	set -- $(arch_elf "$arch")
	assert_eq "$1" "$(elf_byte "$bin/nfqws2" 4)"  "$arch: EI_CLASS у фикстуры"
	assert_eq "$2" "$(elf_byte "$bin/nfqws2" 5)"  "$arch: EI_DATA у фикстуры"
	assert_eq "$3" "$(elf_machine "$bin/nfqws2")" "$arch: e_machine у фикстуры"

	pkgroot="$TMP/root-$arch"
	assert_status 0 sh "$ROOT/scripts/stage.sh" "$TMP/src" "$bin" "$arch" "$pkgroot"

	ipk="$TMP/out-$arch.ipk"
	assert_status 0 sh "$ROOT/scripts/mkipk.sh" "$pkgroot" "$arch" v9.9.9 "$ipk"
	assert_file "$ipk" "$arch: .ipk создан"

	# главная проверка: инспектор должен принять пакет своей архитектуры
	if out=$(sh "$ROOT/scripts/inspect-ipk.sh" "$ipk" "$arch" 2>&1); then
		ok "$arch: inspect-ipk принял пакет"
	else
		bad "$arch: inspect-ipk забраковал пакет"
		echo "$out" | sed 's/^/        /'
	fi

	# и обязан забраковать пакет с бинарниками чужой арки
	case "$arch" in
		mipsel-3.4) other=aarch64-3.10 ;;
		*)          other=mipsel-3.4 ;;
	esac
	if sh "$ROOT/scripts/inspect-ipk.sh" "$ipk" "$other" >/dev/null 2>&1; then
		bad "$arch: inspect-ipk не заметил подмену арки на $other"
	else
		ok "$arch: inspect-ipk ловит подмену арки на $other"
	fi

	# состав пакета
	d="$TMP/x-$arch"; mkdir -p "$d"
	tar -C "$d" -xzf "$ipk"
	mkdir -p "$d/data"; tar -C "$d/data" -xzf "$d/data.tar.gz"
	assert_file "$d/data/./opt/zapret2/nfq2/nfqws2"        "$arch: nfqws2 на месте"
	assert_file "$d/data/./opt/zapret2/init.d/sysv/functions" "$arch: functions на месте"
	# Скрипты установки и отката едут на роутер: откат должен быть доступен и
	# тогда, когда интернета уже нет.
	assert_file "$d/data/./opt/bin/zapret2-install"        "$arch: zapret2-install в пакете"
	assert_file "$d/data/./opt/bin/zapret2-uninstall"      "$arch: zapret2-uninstall в пакете"
	assert_file "$d/data/./opt/etc/zapret2/config"         "$arch: config на месте"
	assert_file "$d/data/./opt/zapret2/blockcheck2.sh"     "$arch: blockcheck2 на месте"
	assert_nofile "$d/data/./opt/zapret2/nfq2/nfqws.c"     "$arch: исходники не попали"
	assert_nofile "$d/data/./opt/zapret2/Makefile"         "$arch: Makefile не попал"
	assert_nofile "$d/data/./opt/zapret2/docs"             "$arch: docs не попали"
	assert_nofile "$d/data/./opt/zapret2/ipset/zapret-hosts-user-exclude.txt.default" \
	                                                       "$arch: *.default вычищены"
	# stage.sh кладёт и наши файлы, и upstream — .stamp из build/ попасть не должен
	assert_nofile "$d/data/./opt/zapret2/.stamp"           "$arch: .stamp не попал"
	# MIT upstream требует нести уведомление об авторстве вместе с кодом
	assert_file "$d/data/./opt/zapret2/LICENSE.upstream.txt"  "$arch: лицензия upstream в пакете"
	assert_file "$d/data/./opt/zapret2/LICENSE.packaging.txt" "$arch: лицензия обвязки в пакете"

	mkdir -p "$d/ctl"; tar -C "$d/ctl" -xzf "$d/control.tar.gz"
	assert_grep "^Architecture: $arch\$" "$d/ctl/control" "$arch: Architecture в control"
	assert_grep "^Version: 9.9.9-"       "$d/ctl/control" "$arch: Version из REF"
	assert_grep "^Installed-Size: [0-9]" "$d/ctl/control" "$arch: Installed-Size посчитан"

	# каждый conffile обязан присутствовать в data
	while IFS= read -r cf; do
		[ -n "$cf" ] || continue
		assert_file "$d/data/.$cf" "$arch: conffile $cf есть в data"
	done <"$d/ctl/conffiles"
done

# сборка без blockcheck2
bin="$TMP/bin-mipsel-3.4"
pkgroot="$TMP/root-nobc"
INCLUDE_BLOCKCHECK=0 sh "$ROOT/scripts/stage.sh" "$TMP/src" "$bin" mipsel-3.4 "$pkgroot" >/dev/null 2>&1
assert_nofile "$pkgroot/opt/zapret2/blockcheck2.sh" "INCLUDE_BLOCKCHECK=0 выкидывает blockcheck2"
assert_file   "$pkgroot/opt/zapret2/nfq2/nfqws2"    "INCLUDE_BLOCKCHECK=0 не ломает остальное"

finish
