#!/bin/sh
# Тесты первичного наполнения списка: zapret2-list --bootstrap и вызов его из
# postinst. Офлайн: upstream ipset/get_*.sh подменяются стабами.
. "$(dirname "$0")/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

LISTTOOL="$ROOT/package/root/opt/bin/zapret2-list"

# setup <имя> — песочница с деревом upstream и конфигом
setup()
{
	SB=$TMP/$1
	mkdir -p "$SB/base/ipset" "$SB/rw/ipset"
	: >"$SB/log"

	cat >"$SB/rw/config" <<'CFG'
WS_USER=nobody
FWTYPE=iptables
MODE_FILTER=none
CFG

	for g in get_reestr_resolvable_domains.sh get_antizapret_domains.sh; do
		cat >"$SB/base/ipset/$g" <<'GET'
#!/bin/sh
echo "getlist ${0##*/}" >>"$STUB_LOG"
if [ "${STUB_LIST_RC:-0}" != 0 ]; then exit "$STUB_LIST_RC"; fi
if [ "${STUB_LIST_EMPTY:-0}" != 1 ]; then
	mkdir -p "$ZAPRET_RW/ipset"
	echo "example.com" | gzip -9c >"$ZAPRET_RW/ipset/zapret-hosts.txt.gz"
fi
exit 0
GET
		chmod 755 "$SB/base/ipset/$g"
	done
}

# list_run <песочница> [аргументы zapret2-list...]
list_run()
{
	sb=$1; shift
	env ZAPRET_BASE="$sb/base" ZAPRET_RW="$sb/rw" ZAPRET_CONFIG="$sb/rw/config" \
	    STUB_LOG="$sb/log" \
	    STUB_LIST_RC="${STUB_LIST_RC-0}" STUB_LIST_EMPTY="${STUB_LIST_EMPTY-0}" \
	    ZAPRET_BOOTSTRAP_SCRIPT="${ZAPRET_BOOTSTRAP_SCRIPT-get_reestr_resolvable_domains.sh}" \
	    ZAPRET_BOOTSTRAP_MODE="${ZAPRET_BOOTSTRAP_MODE-}" \
	    ZAPRET_CRONTAB="$sb/crontab" ZAPRET_CRON_CMD=/opt/bin/zapret2-list \
	    sh "$LISTTOOL" "$@" >"$sb/out" 2>&1
}

# --- удачное наполнение -------------------------------------------------------

setup ok
list_run "$SB" --bootstrap && rc=0 || rc=$?
assert_eq 0 "$rc" "bootstrap: код возврата 0"
assert_grep "getlist get_reestr_resolvable_domains.sh" "$SB/log" "bootstrap зовёт скрипт по умолчанию"
assert_file "$SB/rw/ipset/zapret-hosts.txt.gz" "список лёг на диск"
assert_grep '^MODE_FILTER=autohostlist$' "$SB/rw/config" "по умолчанию включается autohostlist"
assert_grep '^GETLIST=get_reestr_resolvable_domains.sh$' "$SB/rw/config" "GETLIST прописан"
assert_file "$SB/rw/config.bak" "прежний конфиг сохранён"

# --- провалы: режим обязан остаться none --------------------------------------
# Главный инвариант. Без файла списка под фильтр не подпадает ни один домен:
# в hostlist это навсегда, в autohostlist — до тех пор, пока nfqws не доучится
# на сбоях. Оба варианта хуже none, где всё работает сразу.

setup fail-rc
STUB_LIST_RC=2 list_run "$SB" --bootstrap && rc=0 || rc=$?
assert_ne 0 "$rc" "скрипт упал: ненулевой код возврата"
assert_grep '^MODE_FILTER=none$' "$SB/rw/config" "скрипт упал: MODE_FILTER остаётся none"
assert_nogrep '^GETLIST=' "$SB/rw/config" "скрипт упал: GETLIST не прописан"

setup fail-empty
STUB_LIST_EMPTY=1 list_run "$SB" --bootstrap && rc=0 || rc=$?
assert_ne 0 "$rc" "файла нет: ненулевой код возврата"
assert_grep '^MODE_FILTER=none$' "$SB/rw/config" "файла нет: MODE_FILTER остаётся none"

setup fail-noscript
ZAPRET_BOOTSTRAP_SCRIPT=get_такого_нет.sh list_run "$SB" --bootstrap && rc=0 || rc=$?
assert_ne 0 "$rc" "нет такого скрипта: ненулевой код возврата"
assert_grep '^MODE_FILTER=none$' "$SB/rw/config" "нет такого скрипта: MODE_FILTER остаётся none"

# --- уважение к уже настроенному ----------------------------------------------

setup preset
sed 's/^MODE_FILTER=.*/MODE_FILTER=autohostlist/' "$SB/rw/config" >"$SB/c" && mv "$SB/c" "$SB/rw/config"
list_run "$SB" --bootstrap && rc=0 || rc=$?
assert_eq 0 "$rc" "уже настроено: код возврата 0, это не ошибка"
assert_nogrep "getlist" "$SB/log" "уже настроено: ничего не качается"
assert_grep '^MODE_FILTER=autohostlist$' "$SB/rw/config" "уже настроено: режим не перезаписан"

# Список уже лежит (например, от прошлой установки) — качать заново незачем,
# но режим включить надо.
setup present
echo x | gzip -9c >"$SB/rw/ipset/zapret-hosts.txt.gz"
list_run "$SB" --bootstrap
assert_nogrep "getlist" "$SB/log" "список уже есть: повторно не качается"
assert_grep '^MODE_FILTER=autohostlist$' "$SB/rw/config" "список уже есть: режим всё равно включается"

# --- параметризация -----------------------------------------------------------

setup mode-plain
ZAPRET_BOOTSTRAP_MODE=hostlist list_run "$SB" --bootstrap
assert_grep '^MODE_FILTER=hostlist$' "$SB/rw/config" "режим bootstrap задаётся переменной"

setup script-arg
list_run "$SB" --bootstrap get_antizapret_domains.sh
assert_grep "getlist get_antizapret_domains.sh" "$SB/log" "скрипт можно передать аргументом"
assert_grep '^GETLIST=get_antizapret_domains.sh$' "$SB/rw/config" "GETLIST соответствует выбранному скрипту"

# --- обычные режимы zapret2-list не сломались ---------------------------------

setup plain
list_run "$SB" --list
assert_grep "get_reestr_resolvable_domains.sh" "$SB/out" "--list по-прежнему показывает скрипты"
assert_nogrep "getlist" "$SB/log" "--list ничего не запускает"

setup plain-run
list_run "$SB" get_antizapret_domains.sh
assert_grep "getlist get_antizapret_domains.sh" "$SB/log" "явный запуск скрипта работает"
assert_grep '^MODE_FILTER=none$' "$SB/rw/config" "явный запуск конфиг не трогает"

setup plain-getlist
list_run "$SB" && rc=0 || rc=$?
assert_ne 0 "$rc" "без GETLIST и без аргумента — ошибка"
assert_grep "GETLIST" "$SB/out" "подсказано, что задать GETLIST"

# --- автообновление списка через cron -----------------------------------------

setup cron-on
list_run "$SB" --bootstrap
assert_file "$SB/crontab" "bootstrap создал crontab"
assert_grep "zapret2-list" "$SB/crontab" "после bootstrap расписание добавлено"
assert_grep '\*/2' "$SB/crontab" "расписание раз в двое суток"

# Провал загрузки не должен оставлять расписание: обновлять нечего, GETLIST не
# задан, и cron просто ругался бы раз в двое суток.
setup cron-not-on-fail
STUB_LIST_RC=2 list_run "$SB" --bootstrap || true
assert_nogrep "zapret2-list" "$SB/crontab" "провал загрузки: расписание не добавлено"

setup cron-idempotent
list_run "$SB" --bootstrap
list_run "$SB" --cron on
list_run "$SB" --cron on
assert_count 1 "zapret2-list" "$SB/crontab" "повторные вызовы не плодят дубли"

# Файл общий: чужие строки трогать нельзя.
setup cron-foreign
mkdir -p "$SB"
printf '0 5 * * * /opt/bin/чужой-скрипт\n' >"$SB/crontab"
list_run "$SB" --bootstrap
assert_grep 'чужой-скрипт' "$SB/crontab" "чужая строка на месте после включения"
list_run "$SB" --cron off
assert_grep 'чужой-скрипт' "$SB/crontab" "чужая строка на месте после выключения"
assert_nogrep "zapret2-list" "$SB/crontab" "наша строка снята"

setup cron-status
list_run "$SB" --cron status
assert_grep "выключено" "$SB/out" "status: выключено, пока не включали"
list_run "$SB" --bootstrap
list_run "$SB" --cron status
assert_grep "zapret2-list" "$SB/out" "status: показывает строку расписания"

setup cron-off-missing
list_run "$SB" --cron off && rc=0 || rc=$?
assert_eq 0 "$rc" "выключение без crontab-файла не ошибка"

# --- postinst зовёт bootstrap при ручной установке ----------------------------

# Песочница под maintainer-скрипт: ему нужны init, zapret2-list и дерево upstream.
setup_postinst()
{
	SB=$TMP/$1
	mkdir -p "$SB/root/opt/etc/zapret2/ipset" "$SB/root/opt/etc/ndm/netfilter.d" \
	         "$SB/root/opt/bin" "$SB/root/opt/etc/init.d" "$SB/root/opt/var/run"
	: >"$SB/log"

	cat >"$SB/root/opt/etc/zapret2/config" <<'CFG'
WS_USER=nobody
MODE_FILTER=none
CFG

	# init: postinst зовёт `check` и, на обновлении, `start`
	cat >"$SB/root/opt/etc/init.d/S99zapret2" <<'INIT'
#!/bin/sh
echo "init $*" >>"$STUB_LOG"
exit 0
INIT
	cp "$LISTTOOL" "$SB/root/opt/bin/zapret2-list"
	: >"$SB/root/opt/bin/zapret2"
	mkdir -p "$SB/root/opt/zapret2/ipset"
	cat >"$SB/root/opt/zapret2/ipset/get_reestr_resolvable_domains.sh" <<'GET'
#!/bin/sh
echo "getlist ${0##*/}" >>"$STUB_LOG"
if [ "${STUB_LIST_RC:-0}" != 0 ]; then exit "$STUB_LIST_RC"; fi
mkdir -p "$ZAPRET_RW/ipset"
echo "example.com" | gzip -9c >"$ZAPRET_RW/ipset/zapret-hosts.txt.gz"
exit 0
GET
	chmod 755 "$SB/root/opt/etc/init.d/S99zapret2" "$SB/root/opt/bin/zapret2-list" \
	          "$SB/root/opt/zapret2/ipset/get_reestr_resolvable_domains.sh"
}

postinst_run()
{
	sb=$1; shift
	env ZAPRET_ROOT_PREFIX="$sb/root" STUB_LOG="$sb/log" \
	    STUB_LIST_RC="${STUB_LIST_RC-0}" \
	    ZAPRET_NO_LISTS="${ZAPRET_NO_LISTS-}" \
	    sh "$ROOT/package/control/postinst" "$@" >"$sb/out" 2>&1
}

setup_postinst pi-fresh
postinst_run "$SB"
assert_grep "getlist get_reestr_resolvable_domains.sh" "$SB/log" "postinst: чистая установка качает список"
assert_grep '^MODE_FILTER=autohostlist$' "$SB/root/opt/etc/zapret2/config" "postinst: режим переключён"

setup_postinst pi-optout
ZAPRET_NO_LISTS=1 postinst_run "$SB"
assert_nogrep "getlist" "$SB/log" "postinst: ZAPRET_NO_LISTS=1 отключает загрузку"
assert_grep '^MODE_FILTER=none$' "$SB/root/opt/etc/zapret2/config" "postinst: с опт-аутом режим не меняется"

# На обновлении конфиг и списки уже на месте — качать заново незачем.
setup_postinst pi-upgrade
: >"$SB/root/opt/var/run/zapret2.upgrade-restart"
postinst_run "$SB"
assert_nogrep "getlist" "$SB/log" "postinst: обновление список не перекачивает"
assert_grep "init start" "$SB/log" "postinst: обновление поднимает сервис обратно"

# Неудачная загрузка не должна валить установку пакета.
setup_postinst pi-listfail
STUB_LIST_RC=2 postinst_run "$SB" && rc=0 || rc=$?
assert_eq 0 "$rc" "postinst: провал загрузки не валит установку"
assert_grep '^MODE_FILTER=none$' "$SB/root/opt/etc/zapret2/config" "postinst: провал загрузки оставляет none"

# С IPKG_INSTROOT (сборка образа) postinst не должен лезть в сеть вообще.
setup_postinst pi-instroot
env IPKG_INSTROOT="$SB/root" ZAPRET_ROOT_PREFIX="$SB/root" STUB_LOG="$SB/log" \
	sh "$ROOT/package/control/postinst" >"$SB/out" 2>&1
assert_nogrep "getlist" "$SB/log" "postinst: с IPKG_INSTROOT ничего не качает"

# --- prerm снимает расписание при удалении ------------------------------------

prerm_run()
{
	sb=$1; shift
	env ZAPRET_ROOT_PREFIX="$sb/root" STUB_LOG="$sb/log" \
	    sh "$ROOT/package/control/prerm" "$@" >"$sb/out" 2>&1
}

setup_postinst pr-remove
mkdir -p "$SB/root/opt/etc/crontabs"
printf '0 5 * * * /opt/bin/чужой-скрипт\n17 4 */2 * * /opt/bin/zapret2-list >/dev/null 2>&1 # zapret2-list: автообновление списка\n' >"$SB/root/opt/etc/crontabs/root"
prerm_run "$SB" remove
assert_nogrep "zapret2-list" "$SB/root/opt/etc/crontabs/root" "remove: наша строка снята"
assert_grep 'чужой-скрипт' "$SB/root/opt/etc/crontabs/root" "remove: чужая строка не тронута"

# На обновлении строка должна остаться: postinst нового пакета её не вернёт,
# потому что bootstrap там только для чистой установки.
setup_postinst pr-upgrade
mkdir -p "$SB/root/opt/etc/crontabs"
printf '17 4 */2 * * /opt/bin/zapret2-list >/dev/null 2>&1 # zapret2-list: автообновление списка\n' >"$SB/root/opt/etc/crontabs/root"
prerm_run "$SB" upgrade
assert_grep "zapret2-list" "$SB/root/opt/etc/crontabs/root" "upgrade: расписание переживает обновление"

finish
