#!/bin/sh
# postinst / prerm / postrm: сценарии установки, обновления и удаления.
. "$(dirname "$0")/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

PREFIX="$TMP/root"
RUN="$TMP/run"
FLAG="$PREFIX/opt/var/run/zapret2.upgrade-restart"
STATE="$RUN/zapret2.started"
INITLOG="$TMP/initlog"

setup() {
	rm -rf "$PREFIX" "$RUN"
	mkdir -p "$PREFIX/opt/etc/init.d" "$PREFIX/opt/etc/ndm/netfilter.d" \
	         "$PREFIX/opt/bin" "$PREFIX/opt/var/run" "$RUN"
	cat >"$PREFIX/opt/etc/init.d/S99zapret2" <<INIT
#!/bin/sh
echo "\$1" >>"$INITLOG"
[ "\$1" = stop ] && rm -f "$STATE"
exit 0
INIT
	chmod 755 "$PREFIX/opt/etc/init.d/S99zapret2"
	: >"$PREFIX/opt/bin/zapret2"
	: >"$PREFIX/opt/bin/zapret2-list"
	: >"$PREFIX/opt/etc/ndm/netfilter.d/50-zapret2.sh"
	: >"$INITLOG"
}

run_script() { # $1 - имя скрипта, $2 - аргумент opkg
	env ZAPRET_ROOT_PREFIX="$PREFIX" ZAPRET_RUNDIR="$RUN" \
	    sh "$ROOT/package/control/$1" "$2" >/dev/null 2>&1
}

# --- сценарий обновления -------------------------------------------------------
setup
: >"$STATE"
run_script prerm upgrade
assert_file "$FLAG" "prerm upgrade оставляет метку автозапуска"
assert_grep "^stop$" "$INITLOG" "prerm глушит сервис"
run_script postrm upgrade
assert_file "$FLAG" "postrm upgrade не трогает метку автозапуска"
: >"$INITLOG"
run_script postinst configure
assert_grep "^start$" "$INITLOG" "postinst поднимает сервис после обновления"
assert_nofile "$FLAG" "postinst забирает метку автозапуска"

# --- сценарий удаления ---------------------------------------------------------
# РЕГРЕССИЯ: раньше prerm ставил метку и при обычном remove, а postrm её не убирал.
# Метка живёт в /opt/var/run, который переживает удаление пакета, поэтому следующая
# чистая установка стартовала бы сервис с ненастроенным конфигом.
setup
: >"$STATE"
run_script prerm remove
assert_nofile "$FLAG" "prerm remove не оставляет метку автозапуска"
assert_grep "^stop$" "$INITLOG" "prerm remove тоже глушит сервис"
run_script postrm remove
assert_nofile "$FLAG" "postrm remove вычищает метку автозапуска"
assert_nofile "$STATE" "postrm убирает метку запуска"

# --- чистая установка после удаления не должна ничего стартовать ---------------
: >"$INITLOG"
run_script postinst configure
assert_nogrep "^start$" "$INITLOG" "после remove чистая установка не стартует сама"
assert_grep "^check$" "$INITLOG" "postinst всё равно прогоняет check"

# --- метка автозапуска, оставшаяся от прошлого удаления, не должна выстрелить ---
setup
: >"$FLAG"
: >"$INITLOG"
run_script postrm remove
run_script postinst configure
assert_nogrep "^start$" "$INITLOG" "осиротевшая метка снимается на remove и не стреляет"

# --- prerm без запущенного сервиса --------------------------------------------
setup
run_script prerm upgrade
assert_nofile "$FLAG" "prerm upgrade не ставит метку, если сервис не был запущен"

# --- РЕГРЕССИЯ: метка запуска ищется не только в /var/run ----------------------
# Init-скрипт падает в /tmp, если /var/run не пишется; prerm должен это видеть.
setup
ALT="$TMP/altrun"; mkdir -p "$ALT"
: >"$ALT/zapret2.started"
env ZAPRET_ROOT_PREFIX="$PREFIX" ZAPRET_RUNDIR="$ALT" \
    sh "$ROOT/package/control/prerm" upgrade >/dev/null 2>&1
assert_file "$FLAG" "prerm находит метку запуска в альтернативном каталоге"

# --- оффлайн-установка в чужой корень: ничего не делаем ------------------------
setup
: >"$STATE"
: >"$INITLOG"
for s in postinst prerm postrm; do
	env ZAPRET_ROOT_PREFIX="$PREFIX" ZAPRET_RUNDIR="$RUN" IPKG_INSTROOT="$TMP/other" \
	    sh "$ROOT/package/control/$s" configure >/dev/null 2>&1
done
assert_eq "" "$(cat "$INITLOG")" "с IPKG_INSTROOT скрипты не трогают живую систему"
assert_file "$STATE" "с IPKG_INSTROOT метка запуска остаётся нетронутой"

finish
