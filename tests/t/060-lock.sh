#!/bin/sh
# Блокировка init-скрипта: снятие мёртвой, уважение живой, гарантированный таймаут.
. "$(dirname "$0")/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

DEAD_PID=4194304   # заведомо не существует: больше любого pid_max

# --- блокировка от мёртвого процесса снимается ---
sb="$TMP/dead"
make_init_sandbox "$sb"
mkdir -p "$sb/run/zapret2.lock"
echo "$DEAD_PID" >"$sb/run/zapret2.lock/pid"
init_run "$sb" start >/dev/null 2>&1
assert_grep '^run_daemons$' "$sb/log" "блокировка от мёртвого процесса не мешает старту"
assert_file "$sb/run/zapret2.started" "старт прошёл"

# --- блокировка от живого процесса уважается, и ожидание конечно ---
sb="$TMP/live"
make_init_sandbox "$sb"
mkdir -p "$sb/run/zapret2.lock"
echo $$ >"$sb/run/zapret2.lock/pid"     # держит живой процесс — сам тест
t0=$(date +%s)
ZAPRET_LOCK_WAIT=2 init_run "$sb" start >/dev/null 2>&1
rc=$?
t1=$(date +%s)
assert_ne 0 "$rc" "старт при занятой блокировке завершается ошибкой"
assert_nogrep '^run_daemons$' "$sb/log" "занятая блокировка не пускает к демонам"
assert_nofile "$sb/run/zapret2.started" "метка запуска не появляется"
if [ $((t1 - t0)) -ge 1 ] && [ $((t1 - t0)) -le 8 ]; then
	ok "ожидание блокировки уложилось в таймаут ($((t1 - t0))с)"
else
	bad "ожидание блокировки заняло $((t1 - t0))с вместо ~2с"
fi

# --- РЕГРЕССИЯ: воркер отложенной переустановки держит блокировку своим pid ---
# Раньше воркер писал в lock pid уже вышедшего родителя (в сабшелле $$ — это pid
# родительской оболочки), поэтому любой следующий вызов считал блокировку
# протухшей, сносил её и лез в netfilter параллельно с воркером.
sb="$TMP/worker"
make_init_sandbox "$sb"
cat >>"$sb/base/init.d/sysv/functions" <<'SLOW'
zapret_apply_firewall() { sleep 3; _tlog apply_firewall; }
SLOW
init_run "$sb" start >/dev/null 2>&1
: >"$sb/log"
REAPPLY_DELAY=1 init_run "$sb" reapply >/dev/null 2>&1
sleep 2                                  # воркер уже проснулся и держит блокировку
pid=$(cat "$sb/run/zapret2.lock/pid" 2>/dev/null || echo "")
if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
	ok "воркер держит блокировку живым pid ($pid)"
else
	bad "в блокировке воркера pid «$pid» — процесса с таким pid нет"
fi
ZAPRET_LOCK_WAIT=1 init_run "$sb" start-fw >/dev/null 2>&1
assert_count 0 '^apply_firewall$' "$sb/log" "чужой вызов не влез в netfilter мимо блокировки воркера"
sleep 4                                  # даём воркеру доработать
assert_count 1 '^apply_firewall$' "$sb/log" "воркер довёл переустановку до конца"

# --- РЕГРЕССИЯ: цикл ожидания не крутится вечно, если блокировка возвращается ---
# Раньше ветка снятия протухшей блокировки делала continue, не уменьшая счётчик
# и не засыпая: если снять блокировку не удавалось, цикл жёг CPU без таймаута.
if command -v timeout >/dev/null 2>&1; then
	sb="$TMP/flapping"
	make_init_sandbox "$sb"
	(
		i=0
		while [ $i -lt 200 ]; do
			mkdir -p "$sb/run/zapret2.lock" 2>/dev/null
			echo "$DEAD_PID" >"$sb/run/zapret2.lock/pid" 2>/dev/null
			i=$((i + 1))
			sleep 0.05 2>/dev/null || sleep 1
		done
	) &
	flapper=$!
	t0=$(date +%s)
	# тело для sh -c должно уехать неразвёрнутым
	# shellcheck disable=SC2016
	ZAPRET_LOCK_WAIT=3 timeout 25 sh -c '
		env ZAPRET_BASE="$1/base" ZAPRET_RW="$1/rw" ZAPRET_CONFIG="$1/rw/config" \
		    ZAPRET_RUNDIR="$1/run" ZAPRET_TEST_LOG="$1/log" ZAPRET_LOCK_WAIT=3 \
		    sh "$2" start' _ "$sb" "$ROOT/package/root/opt/etc/init.d/S99zapret2" >/dev/null 2>&1
	rc=$?
	t1=$(date +%s)
	kill "$flapper" 2>/dev/null
	wait "$flapper" 2>/dev/null
	assert_ne 124 "$rc" "постоянно возвращающаяся блокировка не подвешивает скрипт"
	if [ $((t1 - t0)) -le 15 ]; then
		ok "цикл ожидания вышел по таймауту за $((t1 - t0))с"
	else
		bad "цикл ожидания крутился $((t1 - t0))с"
	fi
else
	echo "    -- нет утилиты timeout, пропускаю проверку зацикливания"
fi

finish
