#!/bin/sh
# Отложенная переустановка правил после того, как ndm пересобрал netfilter.
# Здесь же регрессии на два дефекта, найденные ревью.
. "$(dirname "$0")/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

REAPPLY_DELAY=1
export REAPPLY_DELAY

# ^apply_firewall$ — именно с якорями: без них шаблон ловит ещё и unapply_firewall
APPLY='^apply_firewall$'

new_sandbox() { # $1 - имя
	sb="$TMP/$1"
	make_init_sandbox "$sb"
	init_run "$sb" start >/dev/null 2>&1
	: >"$sb/log"
	echo "$sb"
}

# --- сервис не запущен: планировать нечего ---
sb=$(new_sandbox off)
init_run "$sb" stop >/dev/null 2>&1
: >"$sb/log"
init_run "$sb" reapply >/dev/null 2>&1
assert_nofile "$sb/run/zapret2.reapply.pending" "остановленный сервис не планирует переустановку"

# --- одна заявка -> одна переустановка ---
sb=$(new_sandbox once)
init_run "$sb" reapply >/dev/null 2>&1
assert_file "$sb/run/zapret2.reapply.pending" "reapply ставит метку коалесцирования"
sleep 3
assert_count 1 "$APPLY" "$sb/log" "одна заявка — одна переустановка правил"
assert_count 1 '^unapply_firewall$' "$sb/log" "перед переустановкой правила снимаются"
assert_nofile "$sb/run/zapret2.reapply.pending" "метка снимается после работы воркера"
assert_nofile "$sb/run/zapret2.lock" "воркер отпускает блокировку"

# --- пачка заявок от ndm коалесцируется в одну переустановку ---
sb=$(new_sandbox burst)
i=0
while [ $i -lt 10 ]; do init_run "$sb" reapply >/dev/null 2>&1; i=$((i + 1)); done
sleep 3
assert_count 1 "$APPLY" "$sb/log" "10 заявок подряд схлопываются в одну переустановку"

# --- РЕГРЕССИЯ: stop внутри окна задержки не должен воскрешать правила ---
# Раньше воркер после sleep ставил правила, не перепроверив метку запуска:
# после `opkg remove` правила остались бы висеть без init-скрипта.
sb=$(new_sandbox stopped_midway)
REAPPLY_DELAY=3 init_run "$sb" reapply >/dev/null 2>&1
init_run "$sb" stop >/dev/null 2>&1
sleep 5
assert_count 0 "$APPLY" "$sb/log" "stop внутри окна отменяет отложенную переустановку"
assert_nofile "$sb/run/zapret2.started" "сервис остался остановленным"

# --- РЕГРЕССИЯ: осиротевшая метка не должна навсегда отключать хук ---
# Раньше любой $PENDING делал reapply вечным no-op, то есть возвращал ровно ту
# поломку, ради которой пакет и существует.
sb=$(new_sandbox stale_pending)
echo 0 >"$sb/run/zapret2.reapply.pending"   # метка из 1970 года = воркера убили
init_run "$sb" reapply >/dev/null 2>&1
sleep 3
assert_count 1 "$APPLY" "$sb/log" "протухшая метка сбрасывается, переустановка происходит"

# --- свежая метка всё-таки коалесцирует ---
sb=$(new_sandbox fresh_pending)
date +%s >"$sb/run/zapret2.reapply.pending"
init_run "$sb" reapply >/dev/null 2>&1
sleep 3
assert_count 0 "$APPLY" "$sb/log" "свежая метка не плодит второго воркера"

# --- хук ndm ---
HOOK="$ROOT/package/root/opt/etc/ndm/netfilter.d/50-zapret2.sh"
sb=$(new_sandbox hook)
cat >"$TMP/fakeinit" <<FAKE
#!/bin/sh
echo "init:\$*" >>"$sb/hooklog"
FAKE
chmod 755 "$TMP/fakeinit"
: >"$sb/hooklog"

env ZAPRET_INIT="$TMP/fakeinit" ZAPRET_RUNDIR="$sb/run" type=iptables sh "$HOOK"
assert_grep "init:reapply" "$sb/hooklog" "хук зовёт reapply при пересборке iptables"

: >"$sb/hooklog"
env ZAPRET_INIT="$TMP/fakeinit" ZAPRET_RUNDIR="$sb/run" type=ebtables sh "$HOOK"
assert_count 0 "init:" "$sb/hooklog" "хук игнорирует ebtables"

: >"$sb/hooklog"
init_run "$sb" stop >/dev/null 2>&1
env ZAPRET_INIT="$TMP/fakeinit" ZAPRET_RUNDIR="$sb/run" type=iptables sh "$HOOK"
assert_count 0 "init:" "$sb/hooklog" "хук молчит, пока сервис остановлен"

finish
