#!/bin/sh
# start/stop/status init-скрипта на подменённом upstream functions.
. "$(dirname "$0")/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
SB="$TMP/sb"
make_init_sandbox "$SB"

# --- start ---
init_run "$SB" start >/dev/null 2>&1
assert_grep run_daemons    "$SB/log" "start поднимает демоны"
assert_grep apply_firewall "$SB/log" "start ставит правила"
assert_file "$SB/run/zapret2.started" "start оставляет метку запуска"
assert_nofile "$SB/run/zapret2.lock"  "start отпускает блокировку"

# --- status ---
out=$(init_run "$SB" status 2>&1)
echo "$out" >"$TMP/status.txt"
assert_grep "помечен как запущенный" "$TMP/status.txt" "status видит метку запуска"
assert_grep "демоны nfqws2 не запущены" "$TMP/status.txt" "status честно говорит, что демонов нет"

# --- stop ---
: >"$SB/log"
init_run "$SB" stop >/dev/null 2>&1
assert_grep unapply_firewall "$SB/log" "stop снимает правила"
assert_grep stop_daemons     "$SB/log" "stop глушит демоны"
assert_nofile "$SB/run/zapret2.started" "stop убирает метку запуска"
assert_nofile "$SB/run/zapret2.lock"    "stop отпускает блокировку"

# --- порядок в stop: правила снимаются до остановки демонов ---
: >"$SB/log"
init_run "$SB" start >/dev/null 2>&1
: >"$SB/log"
init_run "$SB" stop >/dev/null 2>&1
assert_eq "unapply_firewall" "$(head -1 "$SB/log")" "stop сначала снимает правила, потом демонов"

# --- INIT_APPLY_FW=0 ---
: >"$SB/log"
printf 'INIT_APPLY_FW=0\nWS_USER=nobody\n' >"$SB/rw/config"
init_run "$SB" start >/dev/null 2>&1
assert_grep run_daemons "$SB/log" "INIT_APPLY_FW=0: демоны всё равно поднимаются"
assert_nogrep apply_firewall "$SB/log" "INIT_APPLY_FW=0: правила не ставятся"
init_run "$SB" stop >/dev/null 2>&1
printf 'INIT_APPLY_FW=1\nWS_USER=nobody\n' >"$SB/rw/config"

# --- подкоманды firewall/daemons ---
: >"$SB/log"
init_run "$SB" start-fw >/dev/null 2>&1
assert_eq "apply_firewall" "$(cat "$SB/log")" "start-fw трогает только правила"
: >"$SB/log"
init_run "$SB" stop-daemons >/dev/null 2>&1
assert_eq "stop_daemons" "$(cat "$SB/log")" "stop-daemons трогает только демонов"

# --- ENABLED=no и неизвестная команда ---
assert_status 1 init_run "$SB" такой-команды-нет

# --- отсутствие конфига не должно приводить к тихому запуску ---
mv "$SB/rw/config" "$SB/rw/config.bak"
assert_status 1 init_run "$SB" start
assert_nofile "$SB/run/zapret2.started" "без конфига сервис не помечается запущенным"
mv "$SB/rw/config.bak" "$SB/rw/config"

finish
