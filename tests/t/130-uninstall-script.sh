#!/bin/sh
# Тесты полного отката (uninstall.sh). Офлайн: opkg, zapret2, zapret2-list и
# iptables-save подменяются стабами.
#
# Скрипт удаляет, поэтому половина случаев здесь про то, чего он трогать НЕ
# должен: чужие строки в общем crontab, чужие файлы в /opt/tmp, конфиг при
# --keep-config.
. "$(dirname "$0")/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# setup <имя> — роутер с установленным пакетом
setup()
{
	SB=$TMP/$1
	R=$SB/root
	mkdir -p "$R/opt/bin" "$R/opt/etc/init.d" "$R/opt/etc/ndm/netfilter.d" \
	         "$R/opt/etc/zapret2/ipset" "$R/opt/etc/zapret2/custom.d" \
	         "$R/opt/zapret2/ipset" "$R/opt/etc/crontabs" "$R/opt/tmp" \
	         "$R/opt/var/run" "$R/var/run" "$SB/bin"
	: >"$SB/log"

	# файлы пакета
	cat >"$R/opt/etc/init.d/S99zapret2" <<'INIT'
#!/bin/sh
echo "init $*" >>"$STUB_LOG"
exit 0
INIT
	cat >"$R/opt/bin/zapret2-list" <<'LST'
#!/bin/sh
echo "zapret2-list $*" >>"$STUB_LOG"
if [ "$1$2" = "--cronoff" ] && [ -f "$ZAPRET_CRONTAB" ]; then
	grep -v '# zapret2-list: автообновление списка' "$ZAPRET_CRONTAB" >"$ZAPRET_CRONTAB.new" || true
	mv "$ZAPRET_CRONTAB.new" "$ZAPRET_CRONTAB"
fi
exit 0
LST
	: >"$R/opt/bin/zapret2"
	echo 'stub functions' >"$R/opt/zapret2/init.d-functions"
	echo 'hook' >"$R/opt/etc/ndm/netfilter.d/50-zapret2.sh"
	chmod 755 "$R/opt/etc/init.d/S99zapret2" "$R/opt/bin/zapret2-list" \
	          "$R/opt/bin/zapret2" "$R/opt/etc/ndm/netfilter.d/50-zapret2.sh"

	# r/w часть: конфиг, пользовательские и скачанные списки
	printf 'WS_USER=nobody\nDESYNC_MARK=0x40000000\nMODE_FILTER=autohostlist\n' >"$R/opt/etc/zapret2/config"
	echo 'старый конфиг' >"$R/opt/etc/zapret2/config.bak"
	echo 'мой домен' >"$R/opt/etc/zapret2/ipset/zapret-hosts-user.txt"
	echo x | gzip -9c >"$R/opt/etc/zapret2/ipset/zapret-hosts.txt.gz"
	echo 'выученное' >"$R/opt/etc/zapret2/ipset/zapret-hosts-auto.txt"
	echo 'udp fix' >"$R/opt/etc/zapret2/custom.d/10-keenetic-udp-fix"

	# общий crontab: наша строка и чужая
	printf '0 5 * * * /opt/bin/чужой-скрипт\n17 4 */2 * * /opt/bin/zapret2-list >/dev/null 2>&1 # zapret2-list: автообновление списка\n' >"$R/opt/etc/crontabs/root"

	# runtime-метки и мусор в общем /opt/tmp
	: >"$R/var/run/zapret2.started"
	mkdir -p "$R/var/run/zapret2.lock"
	: >"$R/var/run/nfqws2_1.pid"
	: >"$R/opt/var/run/zapret2.upgrade-restart"
	: >"$R/opt/tmp/zapret2_1.0.5.1-2_mipsel-3.4.ipk"
	: >"$R/opt/tmp/чужой-файл.txt"

	cat >"$SB/bin/opkg" <<'OPKG'
#!/bin/sh
echo "opkg $*" >>"$STUB_LOG"
case "$1" in
	list-installed) [ "$STUB_INSTALLED" = 0 ] || echo "zapret2 - 1.0.5.1-2" ;;
	remove) rm -rf "$STUB_ROOT/opt/zapret2" "$STUB_ROOT/opt/etc/init.d/S99zapret2" \
	               "$STUB_ROOT/opt/bin/zapret2" "$STUB_ROOT/opt/bin/zapret2-list" \
	               "$STUB_ROOT/opt/etc/ndm/netfilter.d/50-zapret2.sh" ;;
esac
exit 0
OPKG

	# iptables-save: по умолчанию чисто, STUB_RULES=1 — правила остались
	cat >"$SB/bin/iptables-save" <<'IPT'
#!/bin/sh
[ "${STUB_RULES:-0}" = 1 ] || exit 0
case "$2" in
	mangle) echo "-A POSTROUTING -j NFQUEUE --queue-num 300 --queue-bypass" ;;
	nat)    echo "-A POSTROUTING -o ppp0 -m mark --mark 0x40000000/0x40000000 -j MASQUERADE" ;;
esac
exit 0
IPT
	chmod 755 "$SB/bin/opkg" "$SB/bin/iptables-save"
}

run_uninstall()
{
	sb=$1; shift
	env PATH="$sb/bin:$PATH" STUB_LOG="$sb/log" STUB_ROOT="$sb/root" \
	    STUB_INSTALLED="${STUB_INSTALLED-1}" STUB_RULES="${STUB_RULES-0}" \
	    ZAPRET_ROOT_PREFIX="$sb/root" \
	    ZAPRET_CRONTAB="$sb/root/opt/etc/crontabs/root" \
	    sh "$ROOT/uninstall.sh" "$@" >"$sb/out" 2>&1
}

# --- полный откат -------------------------------------------------------------

setup full
run_uninstall "$SB" --yes && rc=0 || rc=$?
assert_eq 0 "$rc" "полный откат: код возврата 0"
assert_grep "init stop" "$SB/log" "сервис остановлен до удаления файлов"
assert_grep "opkg remove zapret2" "$SB/log" "пакет удалён штатно"
assert_nofile "$SB/root/opt/zapret2" "каталог пакета удалён"
assert_nofile "$SB/root/opt/etc/zapret2" "r/w часть удалена вместе с настройками"
assert_nofile "$SB/root/opt/etc/init.d/S99zapret2" "init-скрипт удалён"
assert_nofile "$SB/root/opt/etc/ndm/netfilter.d/50-zapret2.sh" "хук ndm удалён"
assert_nofile "$SB/root/opt/bin/zapret2" "обёртка удалена"
assert_nofile "$SB/root/var/run/zapret2.started" "метка запуска убрана"
assert_nofile "$SB/root/var/run/zapret2.lock" "блокировка убрана"
assert_nofile "$SB/root/var/run/nfqws2_1.pid" "pid-файл убран"
assert_nofile "$SB/root/opt/var/run/zapret2.upgrade-restart" "метка автозапуска убрана"
assert_nofile "$SB/root/opt/tmp/zapret2_1.0.5.1-2_mipsel-3.4.ipk" "скачанный пакет убран"
assert_grep "следов не осталось" "$SB/out" "итог: чисто"

# --- чего трогать нельзя ------------------------------------------------------

setup foreign
run_uninstall "$SB" --yes
assert_file "$SB/root/opt/tmp/чужой-файл.txt" "чужой файл в /opt/tmp не тронут"
assert_grep 'чужой-скрипт' "$SB/root/opt/etc/crontabs/root" "чужая строка в crontab не тронута"
assert_nogrep "zapret2-list" "$SB/root/opt/etc/crontabs/root" "наша строка из crontab снята"

# --- порядок ------------------------------------------------------------------

# stop должен идти до opkg remove: иначе правила снимать будет уже нечем.
setup order
run_uninstall "$SB" --yes
order=$(grep -n "init stop\|opkg remove" "$SB/log" | head -2 | cut -d: -f2- | tr '\n' '|')
case "$order" in
	"init stop|opkg remove"*) ok "сервис останавливается раньше удаления пакета" ;;
	*) bad "сервис останавливается раньше удаления пакета (порядок: $order)" ;;
esac

# --- --keep-config ------------------------------------------------------------

setup keep
run_uninstall "$SB" --yes --keep-config
assert_file "$SB/root/opt/etc/zapret2/config" "--keep-config: конфиг сохранён"
assert_file "$SB/root/opt/etc/zapret2/ipset/zapret-hosts-user.txt" "--keep-config: пользовательский список сохранён"
assert_file "$SB/root/opt/etc/zapret2/custom.d/10-keenetic-udp-fix" "--keep-config: custom.d сохранён"
assert_nofile "$SB/root/opt/etc/zapret2/ipset/zapret-hosts.txt.gz" "--keep-config: скачанный список всё равно убран"
assert_nofile "$SB/root/opt/etc/zapret2/ipset/zapret-hosts-auto.txt" "--keep-config: автосписок всё равно убран"
assert_nofile "$SB/root/opt/zapret2" "--keep-config: сам пакет всё равно удалён"

# --- --dry-run ----------------------------------------------------------------

setup dry
run_uninstall "$SB" --dry-run && rc=0 || rc=$?
assert_eq 0 "$rc" "--dry-run: код возврата 0"
assert_file "$SB/root/opt/etc/zapret2/config" "--dry-run: конфиг на месте"
# assert_file проверяет -f, поэтому смотрим на файл внутри каталога, а не на сам
# каталог: иначе случай проходил бы мимо цели.
assert_file "$SB/root/opt/zapret2/init.d-functions" "--dry-run: каталог пакета на месте"
assert_grep 'zapret2-list' "$SB/root/opt/etc/crontabs/root" "--dry-run: строка cron на месте"
assert_nogrep "opkg remove" "$SB/log" "--dry-run: opkg не звался"
assert_nogrep "init stop" "$SB/log" "--dry-run: сервис не останавливался"
assert_grep "dry-run" "$SB/out" "--dry-run: показано, что было бы сделано"

# --- сломанная установка ------------------------------------------------------

# opkg не знает про пакет, а файлы лежат: откат всё равно должен вычистить.
setup broken-opkg
STUB_INSTALLED=0 run_uninstall "$SB" --yes && rc=0 || rc=$?
assert_eq 0 "$rc" "opkg не знает про пакет: откат всё равно проходит"
assert_nogrep "opkg remove" "$SB/log" "opkg remove не зовётся впустую"
assert_nofile "$SB/root/opt/zapret2" "файлы вычищены напрямую"
assert_nofile "$SB/root/opt/etc/zapret2" "r/w часть вычищена напрямую"

# Нет zapret2-list, но строка в crontab осталась — снять её всё равно надо.
setup broken-tool
rm -f "$SB/root/opt/bin/zapret2-list"
run_uninstall "$SB" --yes
assert_nogrep "zapret2-list >" "$SB/root/opt/etc/crontabs/root" "строка cron снята без zapret2-list"
assert_grep 'чужой-скрипт' "$SB/root/opt/etc/crontabs/root" "чужая строка при этом цела"

# Нет init-скрипта — сервис не остановить, но откат должен продолжиться.
setup broken-init
rm -f "$SB/root/opt/etc/init.d/S99zapret2"
run_uninstall "$SB" --yes && rc=0 || rc=$?
assert_eq 0 "$rc" "нет init: откат всё равно доходит до конца"
assert_nofile "$SB/root/opt/etc/zapret2" "нет init: остатки всё равно вычищены"

# --- честный отчёт об остатках ------------------------------------------------

# Правила в netfilter скрипт вслепую не трёт — но обязан о них сказать.
setup leftover-rules
STUB_RULES=1 run_uninstall "$SB" --yes && rc=0 || rc=$?
assert_ne 0 "$rc" "остались правила: ненулевой код возврата"
assert_grep "NFQUEUE" "$SB/out" "остались правила: сказано про NFQUEUE"
assert_grep "0x40000000" "$SB/out" "остались правила: сказано про MASQUERADE с меткой"
assert_nogrep "следов не осталось" "$SB/out" "остались правила: не заявляет, что чисто"

# --- ничего не установлено ----------------------------------------------------

setup nothing
rm -rf "$SB/root/opt/zapret2" "$SB/root/opt/etc/zapret2" \
       "$SB/root/opt/etc/init.d/S99zapret2" "$SB/root/opt/bin/zapret2" \
       "$SB/root/opt/etc/ndm/netfilter.d/50-zapret2.sh"
printf '0 5 * * * /opt/bin/чужой-скрипт\n' >"$SB/root/opt/etc/crontabs/root"
run_uninstall "$SB" --yes && rc=0 || rc=$?
assert_eq 0 "$rc" "нечего откатывать: код возврата 0"
assert_grep "откатывать нечего" "$SB/out" "нечего откатывать: сказано прямо"
assert_nogrep "opkg remove" "$SB/log" "нечего откатывать: opkg не трогаем"

# --- подтверждение ------------------------------------------------------------

# Без --yes и без терминала на вводе скрипт обязан отказаться: иначе
# `curl ... | sh` снёс бы настройки без спроса.
setup confirm
run_uninstall "$SB" && rc=0 || rc=$?
assert_ne 0 "$rc" "без --yes и без терминала: отказ"
assert_file "$SB/root/opt/etc/zapret2/config" "без подтверждения ничего не удалено"
assert_nogrep "opkg remove" "$SB/log" "без подтверждения opkg не звался"

setup bad-flag
run_uninstall "$SB" --такого-нет && rc=0 || rc=$?
assert_ne 0 "$rc" "неизвестный ключ: отказ"
assert_file "$SB/root/opt/etc/zapret2/config" "неизвестный ключ: ничего не удалено"

finish
