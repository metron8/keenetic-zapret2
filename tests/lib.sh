# shellcheck shell=sh
# Помощники для тестов. Каждый tests/t/*.sh — отдельный процесс, поэтому
# счётчик падений живёт просто в переменной и отдаётся кодом возврата.

FAILED=0
CASES=0

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export ROOT

ok()   { CASES=$((CASES + 1)); echo "    ok   $*"; }
bad()  { CASES=$((CASES + 1)); FAILED=$((FAILED + 1)); echo "    FAIL $*"; }

assert_eq()      { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (ожидалось «$1», получено «$2»)"; fi; }
assert_ne()      { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3 (не ожидалось «$1»)"; fi; }
assert_file()    { if [ -f "$1" ]; then ok "$2"; else bad "$2 (нет файла $1)"; fi; }
assert_nofile()  { if [ ! -e "$1" ]; then ok "$2"; else bad "$2 (файл $1 существует)"; fi; }
assert_grep()    { if grep -q "$1" "$2" 2>/dev/null; then ok "$3"; else bad "$3 (в $2 нет «$1»)"; fi; }
assert_nogrep()  { if grep -q "$1" "$2" 2>/dev/null; then bad "$3 (в $2 есть «$1»)"; else ok "$3"; fi; }
assert_count()   { # $1 ожидаемое число, $2 шаблон, $3 файл, $4 сообщение
	n=$(grep -c "$2" "$3" 2>/dev/null || true)
	[ -n "$n" ] || n=0
	assert_eq "$1" "$n" "$4"
}
assert_status()  { # $1 ожидаемый код, $2.. команда
	exp=$1; shift
	"$@" >/dev/null 2>&1
	assert_eq "$exp" "$?" "код возврата $exp: $*"
}

finish() {
	echo "    -- случаев: $CASES, падений: $FAILED"
	[ "$FAILED" = 0 ] || exit 1
	exit 0
}

# --- фикстуры -----------------------------------------------------------------

# Минимальный ELF-заголовок нужной архитектуры: этого хватает, чтобы проверить
# логику упаковки и сверку архитектуры в inspect-ipk.sh, не таща сюда реальные
# бинарники под mips/aarch64.
make_stub_elf() {
	# $1 - Entware arch, $2 - выходной файл
	cls=; mach=
	case "$1" in
		mipsel-3.4)   cls='\001'; mach='\010\000' ;;
		aarch64-3.10) cls='\002'; mach='\267\000' ;;
		armv7-3.2)    cls='\001'; mach='\050\000' ;;
		*) echo "make_stub_elf: неизвестная арка $1" >&2; return 1 ;;
	esac
	# 0-3 magic, 4 EI_CLASS, 5 EI_DATA=LE, 6 EI_VERSION, 7-15 нули,
	# 16-17 e_type=ET_EXEC, 18-19 e_machine
	fmt='\177ELF'$cls'\001\001\000\000\000\000\000\000\000\000\000\002\000'$mach
	# shellcheck disable=SC2059
	printf "$fmt" >"$2"
	dd if=/dev/zero bs=1 count=44 >>"$2" 2>/dev/null
	chmod 755 "$2"
}

# Минимальное дерево upstream zapret2: ровно то, что читает stage.sh, плюс
# заведомо лишние файлы (исходники, docs, Makefile) — проверяем, что они
# в пакет не попадают.
make_fake_upstream() {
	# $1 - каталог
	d=$1
	mkdir -p "$d/common" "$d/ipset" "$d/lua" "$d/files/fake" "$d/init.d/sysv" \
	         "$d/blockcheck2.d/standard" "$d/docs" "$d/nfq2" "$d/mdig" "$d/ip2net"
	echo '# stub base.sh'            >"$d/common/base.sh"
	echo '# stub linux_fw.sh'        >"$d/common/linux_fw.sh"
	echo '# stub def.sh'             >"$d/ipset/def.sh"
	echo '# stub get_user.sh'        >"$d/ipset/get_user.sh"
	echo 'user list'                 >"$d/ipset/zapret-hosts-user-exclude.txt.default"
	echo '-- stub lua'               >"$d/lua/zapret-lib.lua"
	printf 'fakepayload'             >"$d/files/fake/tls.bin"
	echo '# stub functions'          >"$d/init.d/sysv/functions"
	echo '# stub config.default'     >"$d/config.default"
	echo '#!/bin/sh'                 >"$d/blockcheck2.sh"
	echo '# standard strategy'       >"$d/blockcheck2.d/standard/10-test"
	# лишнее — не должно попасть в .ipk
	echo 'int main(){}'              >"$d/nfq2/nfqws.c"
	echo 'all:'                      >"$d/Makefile"
	echo 'manual'                    >"$d/docs/manual.md"
	echo 'MIT License upstream'      >"$d/docs/LICENSE.txt"
}

# Песочница для init-скрипта: подменяем upstream functions стабом, который
# пишет вызовы в лог вместо того, чтобы трогать настоящий netfilter.
make_init_sandbox() {
	# $1 - каталог песочницы
	sb=$1
	mkdir -p "$sb/base/init.d/sysv" "$sb/rw/custom.d" "$sb/run"
	cat >"$sb/base/init.d/sysv/functions" <<'FUNCS'
# стаб вместо upstream init.d/sysv/functions
. "$ZAPRET_CONFIG"
QNUM=${QNUM:-300}
WS_USER=${WS_USER:-nobody}
USEROPT="--user=$WS_USER"
PIDDIR=/var/run
CUSTOM_DIR="$ZAPRET_RW/init.d/sysv"
_tlog() { echo "$1" >>"$ZAPRET_TEST_LOG"; }
zapret_run_daemons()      { _tlog run_daemons; }
zapret_stop_daemons()     { _tlog stop_daemons; }
zapret_apply_firewall()   { _tlog apply_firewall; }
zapret_unapply_firewall() { _tlog unapply_firewall; }
zapret_reload_ifsets()    { _tlog reload_ifsets; }
zapret_list_ifsets()      { _tlog list_ifsets; }
zapret_list_table()       { _tlog list_table; }
FUNCS
	cat >"$sb/rw/config" <<'CFG'
INIT_APPLY_FW=1
WS_USER=nobody
CFG
	: >"$sb/log"
}

# Запуск init-скрипта в песочнице: init_run <песочница> <команда...>
init_run() {
	sb=$1; shift
	env ZAPRET_BASE="$sb/base" ZAPRET_RW="$sb/rw" ZAPRET_CONFIG="$sb/rw/config" \
	    ZAPRET_RUNDIR="$sb/run" ZAPRET_TEST_LOG="$sb/log" ZAPRET_LOCK_WAIT="${ZAPRET_LOCK_WAIT:-2}" \
	    REAPPLY_DELAY="${REAPPLY_DELAY:-1}" \
	    sh "$ROOT/package/root/opt/etc/init.d/S99zapret2" "$@"
}
