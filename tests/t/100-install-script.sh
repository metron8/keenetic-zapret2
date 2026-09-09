#!/bin/sh
# Тесты скрипта установки install.sh. Полностью офлайн: opkg, curl и сам zapret2
# подменяются стабами, которые пишут вызовы в лог; «релиз» лежит в каталоге.
. "$(dirname "$0")/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

VER=1.0.5.1-1

# Песочница: prefix-корень, каталог «релиза», каталог стабов для PATH.
# setup <имя> [конфиг-шаблон]
setup()
{
	SB=$TMP/$1
	mkdir -p "$SB/root/opt/etc/zapret2" "$SB/root/opt/bin" "$SB/rel" "$SB/bin"
	: >"$SB/log"

	if [ -n "${2:-}" ]; then
		cp "$2" "$SB/config.tmpl"
	else
		cat >"$SB/config.tmpl" <<'CFG'
WS_USER=nobody
FWTYPE=iptables
#IFACE_WAN=ppp0
NFQWS2_OPT="stub"
MODE_FILTER=none
CFG
	fi

	# «релиз»: пакеты обеих арок и настоящий sha256sum.txt по ним
	echo "fake ipk mipsel" >"$SB/rel/zapret2_${VER}_mipsel-3.4.ipk"
	echo "fake ipk arm64"  >"$SB/rel/zapret2_${VER}_aarch64-3.10.ipk"
	( cd "$SB/rel" && sha256sum ./*.ipk >sha256sum.txt )

	# /proc/net/route: один маршрут по умолчанию через ppp0 (табы обязательны)
	printf 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n' >"$SB/route"
	printf 'ppp0\t00000000\t0100A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n' >>"$SB/route"
	printf 'br0\t0000A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n' >>"$SB/route"

	cat >"$SB/bin/opkg" <<'OPKG'
#!/bin/sh
echo "opkg $*" >>"$STUB_LOG"
case "$1" in
	print-architecture)
		echo "arch all 1"
		echo "arch noarch 1"
		[ -n "$STUB_ARCH" ] && echo "arch $STUB_ARCH 10"
		;;
	list-installed)
		[ -n "$STUB_INSTALLED" ] && echo "zapret2 - $STUB_INSTALLED"
		;;
	install)
		mkdir -p "$STUB_ROOT/opt/etc/zapret2/ipset" "$STUB_ROOT/opt/bin"
		cp "$STUB_CONFIG_TMPL" "$STUB_ROOT/opt/etc/zapret2/config"
		cp "$STUB_ZAPRET" "$STUB_ROOT/opt/bin/zapret2"
		# zapret2-list — настоящий из пакета: в нём и живёт логика bootstrap
		cp "$STUB_LIST" "$STUB_ROOT/opt/bin/zapret2-list"
		chmod 755 "$STUB_ROOT/opt/bin/zapret2" "$STUB_ROOT/opt/bin/zapret2-list"
		cp -r "$STUB_UPSTREAM" "$STUB_ROOT/opt/zapret2"
		;;
esac
exit 0
OPKG

	# Стаб curl: понимает -o и --retry, копирует файл из «релиза» по имени.
	cat >"$SB/bin/curl" <<'CURL'
#!/bin/sh
dest=; url=
while [ $# -gt 0 ]; do
	case "$1" in
		-o)       dest=$2; shift 2 ;;
		--retry)  shift 2 ;;
		-*)       shift ;;
		*)        url=$1; shift ;;
	esac
done
name=${url##*/}
echo "curl $name" >>"$STUB_LOG"
if [ -f "$STUB_REL/$name" ]; then cp "$STUB_REL/$name" "$dest"; exit 0; fi
exit 22
CURL

	# Фальшивое дерево upstream: только ipset/get_*.sh, которые зовёт zapret2-list.
	# STUB_LIST_RC!=0 — скрипт упал; STUB_LIST_EMPTY=1 — отработал успешно, но
	# файла не создал. Это разные способы провалиться, и оба обязаны оставить
	# MODE_FILTER=none.
	mkdir -p "$SB/upstream/ipset"
	for g in get_reestr_resolvable_domains.sh get_antizapret_domains.sh get_user.sh; do
		cat >"$SB/upstream/ipset/$g" <<'GET'
#!/bin/sh
echo "getlist ${0##*/}" >>"$STUB_LOG"
if [ "${STUB_LIST_RC:-0}" != 0 ]; then exit "$STUB_LIST_RC"; fi
if [ "${STUB_LIST_EMPTY:-0}" != 1 ]; then
	mkdir -p "$ZAPRET_RW/ipset"
	echo "example.com" | gzip -9c >"$ZAPRET_RW/ipset/zapret-hosts.txt.gz"
fi
exit 0
GET
		chmod 755 "$SB/upstream/ipset/$g"
	done

	cat >"$SB/zapret2.stub" <<'ZAP'
#!/bin/sh
echo "zapret2 $*" >>"$STUB_LOG"
case "$1" in
	check)  exit "${STUB_CHECK_RC:-0}" ;;
	status) exit "${STUB_STATUS_RC:-0}" ;;
esac
exit 0
ZAP

	chmod 755 "$SB/bin/opkg" "$SB/bin/curl" "$SB/zapret2.stub"
}

# run_install <песочница> [ключи...] — код возврата остаётся в $?
run_install()
{
	sb=$1; shift
	env PATH="$sb/bin:$PATH" \
	    STUB_LOG="$sb/log" STUB_REL="$sb/rel" STUB_ROOT="$sb/root" \
	    STUB_CONFIG_TMPL="$sb/config.tmpl" STUB_ZAPRET="$sb/zapret2.stub" \
	    STUB_LIST="$ROOT/package/root/opt/bin/zapret2-list" \
	    STUB_UPSTREAM="$sb/upstream" \
	    STUB_LIST_RC="${STUB_LIST_RC-0}" STUB_LIST_EMPTY="${STUB_LIST_EMPTY-0}" \
	    STUB_ARCH="${STUB_ARCH-mipsel-3.4}" \
	    STUB_INSTALLED="${STUB_INSTALLED-}" \
	    STUB_CHECK_RC="${STUB_CHECK_RC-0}" \
	    STUB_STATUS_RC="${STUB_STATUS_RC-0}" \
	    ZAPRET_ROOT_PREFIX="$sb/root" \
	    ZAPRET_INSTALL_BASE="https://example.invalid/rel" \
	    ZAPRET_ROUTE_FILE="$sb/route" \
	    sh "$ROOT/install.sh" "$@" >"$sb/out" 2>&1
}

# --- определение архитектуры --------------------------------------------------

setup arch-mips
run_install "$SB" && rc=0 || rc=$?
assert_eq 0 "$rc" "mipsel: скрипт отработал успешно"
assert_grep "curl zapret2_${VER}_mipsel-3.4.ipk" "$SB/log" "mipsel: скачан пакет нужной арки"
assert_nogrep "aarch64" "$SB/log" "mipsel: пакет чужой арки не трогали"

setup arch-arm
STUB_ARCH=aarch64-3.10 run_install "$SB"
assert_grep "curl zapret2_${VER}_aarch64-3.10.ipk" "$SB/log" "aarch64: скачан пакет нужной арки"

setup arch-none
STUB_ARCH='' run_install "$SB" && rc=0 || rc=$?
assert_ne 0 "$rc" "неизвестная арка: скрипт останавливается"
assert_nogrep "opkg install" "$SB/log" "неизвестная арка: пакет не ставится"
assert_grep "arch=" "$SB/out" "неизвестная арка: подсказывает ключ --arch"

setup arch-explicit
STUB_ARCH='' run_install "$SB" --arch=aarch64-3.10
assert_grep "curl zapret2_${VER}_aarch64-3.10.ipk" "$SB/log" "--arch перебивает автоопределение"

# --- сверка контрольной суммы -------------------------------------------------

setup sha-ok
run_install "$SB"
assert_grep "curl sha256sum.txt" "$SB/log" "sha256sum.txt скачивается"
assert_grep "opkg install" "$SB/log" "при сошедшейся сумме пакет ставится"

setup sha-bad
echo "подменённый пакет" >"$SB/rel/zapret2_${VER}_mipsel-3.4.ipk"
run_install "$SB" && rc=0 || rc=$?
assert_ne 0 "$rc" "битая сумма: скрипт останавливается"
assert_nogrep "opkg install" "$SB/log" "битая сумма: пакет НЕ ставится"
assert_nofile "$SB/root/opt/tmp/zapret2_${VER}_mipsel-3.4.ipk" "битая сумма: скачанный файл удалён"

setup sha-missing
rm "$SB/rel/sha256sum.txt"
run_install "$SB" && rc=0 || rc=$?
assert_ne 0 "$rc" "нет sha256sum.txt: скрипт останавливается"
assert_nogrep "opkg install" "$SB/log" "нет sha256sum.txt: пакет НЕ ставится"

setup sha-skip
echo "подменённый пакет" >"$SB/rel/zapret2_${VER}_mipsel-3.4.ipk"
run_install "$SB" --no-verify
assert_grep "opkg install" "$SB/log" "--no-verify: ставит без сверки"

setup ipk-local
echo "локальный пакет" >"$TMP/local.ipk"
run_install "$SB" --ipk="$TMP/local.ipk"
assert_nogrep "curl" "$SB/log" "--ipk: ничего не качает"
assert_grep "opkg install" "$SB/log" "--ipk: ставит с диска"

# --- WAN-интерфейс ------------------------------------------------------------

setup iface-auto
run_install "$SB"
assert_grep '^IFACE_WAN=ppp0$' "$SB/root/opt/etc/zapret2/config" "IFACE_WAN определён по маршруту и вписан"
assert_nogrep '^#IFACE_WAN=' "$SB/root/opt/etc/zapret2/config" "закомментированная строка заменена, а не продублирована"
assert_file "$SB/root/opt/etc/zapret2/config.bak" "прежний конфиг сохранён в .bak"

setup iface-flag
run_install "$SB" --iface=eth3
assert_grep '^IFACE_WAN=eth3$' "$SB/root/opt/etc/zapret2/config" "--iface перебивает автоопределение"

cat >"$TMP/cfg-with-iface" <<'CFG'
WS_USER=nobody
IFACE_WAN=nwg0
CFG
setup iface-preset "$TMP/cfg-with-iface"
run_install "$SB" --no-lists
assert_grep '^IFACE_WAN=nwg0$' "$SB/root/opt/etc/zapret2/config" "уже заданный IFACE_WAN не перезаписан"
assert_nofile "$SB/root/opt/etc/zapret2/config.bak" "конфиг не трогали — бэкап не нужен"

cat >"$TMP/cfg-no-placeholder" <<'CFG'
WS_USER=nobody
FWTYPE=iptables
CFG
setup iface-append "$TMP/cfg-no-placeholder"
run_install "$SB"
assert_grep '^IFACE_WAN=ppp0$' "$SB/root/opt/etc/zapret2/config" "без строки-заготовки IFACE_WAN дописывается в конец"
assert_grep '^WS_USER=nobody$' "$SB/root/opt/etc/zapret2/config" "дописывание не портит остальной конфиг"

setup iface-many
printf 'eth3\t00000000\t0100A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n' >>"$SB/route"
run_install "$SB" && rc=0 || rc=$?
assert_ne 0 "$rc" "несколько маршрутов по умолчанию: скрипт не угадывает"
assert_grep "iface=" "$SB/out" "несколько маршрутов: подсказывает ключ --iface"

setup iface-none
printf 'Iface\tDestination\tGateway\n' >"$SB/route"
run_install "$SB" && rc=0 || rc=$?
assert_ne 0 "$rc" "нет маршрута по умолчанию: скрипт останавливается"

# --- списки доменов -----------------------------------------------------------

setup lists-ok
run_install "$SB"
assert_grep "getlist get_reestr_resolvable_domains.sh" "$SB/log" "список качается по умолчанию"
assert_file "$SB/root/opt/etc/zapret2/ipset/zapret-hosts.txt.gz" "список лёг на диск"
assert_grep '^MODE_FILTER=autohostlist$' "$SB/root/opt/etc/zapret2/config" "после загрузки включается autohostlist"
assert_grep '^GETLIST=get_reestr_resolvable_domains.sh$' "$SB/root/opt/etc/zapret2/config" "GETLIST прописан для будущих обновлений"

# Главный предохранитель: hostlist с пустым списком означает, что nfqws не
# обрабатывает ничего. Если скачать не удалось — режим обязан остаться none.
setup lists-download-failed
STUB_LIST_RC=2 run_install "$SB"
assert_grep '^MODE_FILTER=none$' "$SB/root/opt/etc/zapret2/config" "скрипт списка упал: MODE_FILTER остаётся none"
assert_nogrep '^GETLIST=' "$SB/root/opt/etc/zapret2/config" "скрипт списка упал: GETLIST не прописан"

setup lists-empty
STUB_LIST_EMPTY=1 run_install "$SB"
assert_grep '^MODE_FILTER=none$' "$SB/root/opt/etc/zapret2/config" "скрипт отработал, но файла нет: MODE_FILTER остаётся none"

setup lists-off
run_install "$SB" --no-lists
assert_nogrep "getlist" "$SB/log" "--no-lists: список не качается"
assert_grep '^MODE_FILTER=none$' "$SB/root/opt/etc/zapret2/config" "--no-lists: режим не меняется"

setup lists-plain
run_install "$SB" --hostlist
assert_grep '^MODE_FILTER=hostlist$' "$SB/root/opt/etc/zapret2/config" "--hostlist: простой режим без самопополнения"

setup lists-custom
run_install "$SB" --lists=get_antizapret_domains.sh
assert_grep "getlist get_antizapret_domains.sh" "$SB/log" "--lists выбирает другой скрипт"

cat >"$TMP/cfg-filter-set" <<'CFG'
WS_USER=nobody
IFACE_WAN=ppp0
MODE_FILTER=autohostlist
CFG
setup lists-preset "$TMP/cfg-filter-set"
run_install "$SB"
assert_nogrep "getlist" "$SB/log" "уже настроенный MODE_FILTER: список не перекачивается"
assert_grep '^MODE_FILTER=autohostlist$' "$SB/root/opt/etc/zapret2/config" "уже настроенный MODE_FILTER не перезаписан"

# Список должен лечь ДО старта: иначе демон поднимется с пустым фильтром.
setup lists-order
run_install "$SB"
order=$(grep -n "getlist\|zapret2 start" "$SB/log" | head -2 | cut -d: -f2- | tr '\n' '|')
case "$order" in
	"getlist "*"|zapret2 start"*) ok "список качается раньше старта сервиса" ;;
	*) bad "список качается раньше старта сервиса (порядок: $order)" ;;
esac

# --- запуск сервиса -----------------------------------------------------------

setup start-clean
run_install "$SB" && rc=0 || rc=$?
assert_eq 0 "$rc" "чистый check: код возврата 0"
assert_grep "zapret2 check" "$SB/log" "check прогоняется"
assert_grep "zapret2 start" "$SB/log" "чистый check: сервис запускается"
assert_grep "zapret2 status" "$SB/log" "после старта показывается status"

setup start-dirty
STUB_CHECK_RC=1 run_install "$SB" && rc=0 || rc=$?
assert_ne 0 "$rc" "check со сбоем: ненулевой код возврата"
assert_nogrep "zapret2 start" "$SB/log" "check со сбоем: сервис НЕ запускается"
assert_grep "НЕ запущен" "$SB/out" "check со сбоем: сказано, что сервис не запущен"

setup start-never
run_install "$SB" --no-start
assert_nogrep "zapret2 start" "$SB/log" "--no-start: сервис не запускается даже при чистом check"
assert_grep "zapret2 check" "$SB/log" "--no-start: check всё равно прогоняется"

setup start-forced
STUB_CHECK_RC=1 run_install "$SB" --force-start
assert_grep "zapret2 start" "$SB/log" "--force-start: запускает вопреки сбоям check"

setup status-unhappy
STUB_STATUS_RC=1 run_install "$SB"
assert_grep "restart-fw" "$SB/out" "недовольный status: подсказывает restart-fw"

# --- повторная установка ------------------------------------------------------

setup reinstall-same
cp "$SB/config.tmpl" "$SB/root/opt/etc/zapret2/config"
cp "$SB/zapret2.stub" "$SB/root/opt/bin/zapret2"
STUB_INSTALLED=$VER run_install "$SB"
assert_nogrep "opkg install" "$SB/log" "та же версия: установка пропускается"
assert_nogrep "curl" "$SB/log" "та же версия: ничего не качается"
assert_grep "zapret2 check" "$SB/log" "та же версия: настройка и проверка всё равно идут"

setup reinstall-force
cp "$SB/config.tmpl" "$SB/root/opt/etc/zapret2/config"
cp "$SB/zapret2.stub" "$SB/root/opt/bin/zapret2"
STUB_INSTALLED=$VER run_install "$SB" --force
assert_grep "opkg install --force-reinstall" "$SB/log" "--force: переустанавливает ту же версию"

setup reinstall-older
cp "$SB/config.tmpl" "$SB/root/opt/etc/zapret2/config"
cp "$SB/zapret2.stub" "$SB/root/opt/bin/zapret2"
STUB_INSTALLED=1.0.4.0-1 run_install "$SB"
assert_grep "opkg install" "$SB/log" "другая версия: обновляется без --force"

# --- ключи --------------------------------------------------------------------

setup help
run_install "$SB" --help && rc=0 || rc=$?
assert_eq 0 "$rc" "--help: код возврата 0"
assert_nogrep "opkg install" "$SB/log" "--help: ничего не делает"

setup bad-flag
run_install "$SB" --такого-ключа-нет && rc=0 || rc=$?
assert_ne 0 "$rc" "неизвестный ключ: скрипт останавливается"
assert_nogrep "opkg install" "$SB/log" "неизвестный ключ: ничего не ставится"

finish
