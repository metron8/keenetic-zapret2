#!/bin/sh
# Полный откат zapret2 на роутере Keenetic (Entware): вернуть роутер в состояние
# «как будто пакет не ставили».
#
# Запускать НА РОУТЕРЕ, под root:
#   curl -fL -o /opt/tmp/uninstall.sh https://raw.githubusercontent.com/metron8/keenetic-zapret2/main/uninstall.sh
#   sh /opt/tmp/uninstall.sh
#
# Порядок важен и идёт от «пока файлы на месте» к «подчистить остатки»:
#   1. zapret2 stop  - снять правила netfilter и погасить демоны;
#   2. снять строку автообновления из /opt/etc/crontabs/root;
#   3. opkg remove   - штатное удаление (prerm/postrm сделают то же ещё раз);
#   4. вычистить то, что opkg намеренно оставляет: conffiles (конфиг, списки,
#      custom.d), скачанные и автособранные списки, config.bak, runtime-метки;
#   5. проверить, что ничего не осталось, и честно доложить, если осталось.
#
# Скрипт рассчитан и на сломанную установку: каждый шаг best-effort, отсутствие
# файла или падение opkg не останавливают откат.
#
# Ключи: см. `sh uninstall.sh --help`.

set -e

PREFIX=${ZAPRET_ROOT_PREFIX:-}

ZAPRET_BIN=$PREFIX/opt/bin/zapret2
ZAPRET_LIST_BIN=$PREFIX/opt/bin/zapret2-list
ZAPRET_BASE_DIR=$PREFIX/opt/zapret2
ZAPRET_RW_DIR=$PREFIX/opt/etc/zapret2
CONFIG=$ZAPRET_RW_DIR/config
INIT=$PREFIX/opt/etc/init.d/S99zapret2
NDM_HOOK=$PREFIX/opt/etc/ndm/netfilter.d/50-zapret2.sh
CRONTAB=${ZAPRET_CRONTAB:-$PREFIX/opt/etc/crontabs/root}
CRON_MARK='# zapret2-list: автообновление списка'
TMPDIR_R=$PREFIX/opt/tmp

KEEP_CONFIG=0
ASSUME_YES=0
DRY=0

msg()  { echo "==> $*"; }
warn() { echo "ВНИМАНИЕ: $*" >&2; }
die()  { echo "ОШИБКА: $*" >&2; exit 1; }

usage()
{
	cat <<'USAGE'
Полный откат zapret2 на Keenetic. Запускать на роутере под root.

  sh uninstall.sh [ключи]

Ключи:
  --keep-config   не удалять /opt/etc/zapret2 (конфиг, списки, custom.d)
  --dry-run       только показать, что будет сделано, ничего не менять
  -y, --yes       не спрашивать подтверждения
  -h, --help      это сообщение

Без --keep-config удаляются и настройки, и скачанные списки: это полный откат.
Подтверждение обязательно, если стандартный ввод не терминал — тогда нужен --yes.
USAGE
}

for a in "$@"; do
	case "$a" in
		--keep-config) KEEP_CONFIG=1 ;;
		--dry-run)     DRY=1 ;;
		-y|--yes)      ASSUME_YES=1 ;;
		-h|--help)     usage; exit 0 ;;
		*)             usage >&2; die "неизвестный ключ: $a" ;;
	esac
done

# С ZAPRET_ROOT_PREFIX (только тесты) живую систему не трогаем — root не нужен.
if [ -z "$PREFIX" ] && [ "$(id -u)" != 0 ]; then
	die "нужны права root — зайди на роутер как root"
fi

# run <команда...> — выполняет либо печатает, если --dry-run
run()
{
	if [ "$DRY" = 1 ]; then
		echo "  [dry-run] $*"
	else
		"$@" || true
	fi
}

# --- что вообще есть ----------------------------------------------------------

found=0
for p in "$ZAPRET_BASE_DIR" "$ZAPRET_RW_DIR" "$INIT" "$ZAPRET_BIN" "$NDM_HOOK"; do
	[ -e "$p" ] && found=1
done
if [ -f "$CRONTAB" ] && grep -q "$CRON_MARK" "$CRONTAB" 2>/dev/null; then
	found=1
fi
if [ "$found" = 0 ]; then
	msg "следов zapret2 не нашёл — откатывать нечего"
	exit 0
fi

# Значения из конфига нужны для проверки в конце, а конфиг мы удалим. Читаем сейчас.
DESYNC_MARK=$(sed -n 's/^[[:space:]]*DESYNC_MARK=//p' "$CONFIG" 2>/dev/null | head -n1)
[ -n "$DESYNC_MARK" ] || DESYNC_MARK=0x40000000

# --- подтверждение ------------------------------------------------------------

if [ "$ASSUME_YES" = 0 ] && [ "$DRY" = 0 ]; then
	echo "Будет удалён пакет zapret2, сняты правила netfilter и строка cron."
	if [ "$KEEP_CONFIG" = 0 ]; then
		echo "ВМЕСТЕ С НАСТРОЙКАМИ И СПИСКАМИ: $ZAPRET_RW_DIR будет удалён целиком."
		echo "Сохранить их: запусти с --keep-config"
	else
		echo "Настройки в $ZAPRET_RW_DIR останутся (--keep-config)."
	fi
	if [ -t 0 ]; then
		printf 'Продолжить? [y/N] '
		read -r answer
		case "$answer" in
			y|Y|yes|Yes|да) ;;
			*) msg "отменено"; exit 1 ;;
		esac
	else
		die "стандартный ввод не терминал — подтверди явно ключом --yes"
	fi
fi

[ "$DRY" = 0 ] || msg "режим --dry-run: ничего меняться не будет"

# --- 1. остановить сервис -----------------------------------------------------

if [ -x "$INIT" ]; then
	msg "останавливаю сервис (снимутся правила netfilter и демоны)"
	run "$INIT" stop
else
	warn "нет $INIT — сервис не остановить штатно, проверю остатки в конце"
fi

# --- 2. снять автообновление --------------------------------------------------

if [ -x "$ZAPRET_LIST_BIN" ]; then
	msg "снимаю строку автообновления из cron"
	if [ "$DRY" = 1 ]; then
		echo "  [dry-run] $ZAPRET_LIST_BIN --cron off"
	else
		ZAPRET_CRONTAB="$CRONTAB" "$ZAPRET_LIST_BIN" --cron off >/dev/null 2>&1 || true
	fi
elif [ -f "$CRONTAB" ] && grep -q "$CRON_MARK" "$CRONTAB" 2>/dev/null; then
	# Пакет сломан, но строка в общем crontab осталась — снимаем сами, чужие не трогая.
	msg "снимаю строку автообновления из cron (без zapret2-list)"
	if [ "$DRY" = 1 ]; then
		echo "  [dry-run] удалить строку с меткой из $CRONTAB"
	else
		grep -v "$CRON_MARK" "$CRONTAB" >"$CRONTAB.new" 2>/dev/null || true
		mv "$CRONTAB.new" "$CRONTAB"
	fi
fi

# --- 3. штатное удаление пакета -----------------------------------------------

if command -v opkg >/dev/null 2>&1; then
	if opkg list-installed zapret2 2>/dev/null | grep -q .; then
		msg "удаляю пакет через opkg"
		run opkg remove zapret2
	else
		msg "opkg не считает zapret2 установленным — чищу файлы напрямую"
	fi
else
	warn "opkg не найден — чищу файлы напрямую"
fi

# --- 4. остатки, которые opkg намеренно оставляет -----------------------------

msg "убираю остатки"

# Конфиг, списки и custom.d — conffiles, opkg их сохраняет.
if [ "$KEEP_CONFIG" = 0 ]; then
	run rm -rf "$ZAPRET_RW_DIR"
else
	# Даже при --keep-config скачанные списки смысла не имеют без пакета,
	# а весят прилично. Пользовательские списки и конфиг оставляем.
	run rm -f "$ZAPRET_RW_DIR/ipset/zapret-hosts.txt" \
	          "$ZAPRET_RW_DIR/ipset/zapret-hosts.txt.gz" \
	          "$ZAPRET_RW_DIR/ipset/zapret-hosts-auto.txt" \
	          "$ZAPRET_RW_DIR/ipset/zapret-hosts-auto-debug.log"
fi

# Каталог пакета: обычно его сносит opkg, но при сломанной установке — нет.
run rm -rf "$ZAPRET_BASE_DIR"

# Файлы пакета, если opkg до них не добрался.
run rm -f "$INIT" "$NDM_HOOK" "$ZAPRET_BIN" "$ZAPRET_LIST_BIN"

# Runtime-метки: init кладёт их в /var/run, а если он не пишется — в /tmp.
for d in ${ZAPRET_RUNDIR:-} "$PREFIX/var/run" "$PREFIX/tmp"; do
	[ -d "$d" ] || continue
	run rm -f "$d/zapret2.started" "$d/zapret2.reapply.pending"
	run rm -rf "$d/zapret2.lock"
	run rm -f "$d"/nfqws2_*.pid
done
run rm -f "$PREFIX/opt/var/run/zapret2.upgrade-restart"

# То, что мог скачать install.sh. Каталог общий — трогаем только своё.
run rm -f "$TMPDIR_R"/zapret2_*.ipk "$TMPDIR_R/sha256sum.txt"

# --- 5. проверка -------------------------------------------------------------

if [ "$DRY" = 1 ]; then
	echo
	msg "--dry-run окончен, ничего не изменено"
	exit 0
fi

echo
msg "проверяю, что ничего не осталось"
left=0

for p in "$ZAPRET_BASE_DIR" "$INIT" "$NDM_HOOK" "$ZAPRET_BIN" "$ZAPRET_LIST_BIN"; do
	if [ -e "$p" ]; then
		echo "ОСТАЛОСЬ  $p"
		left=1
	fi
done
if [ "$KEEP_CONFIG" = 0 ] && [ -e "$ZAPRET_RW_DIR" ]; then
	echo "ОСТАЛОСЬ  $ZAPRET_RW_DIR"
	left=1
fi
if [ -f "$CRONTAB" ] && grep -q "$CRON_MARK" "$CRONTAB" 2>/dev/null; then
	echo "ОСТАЛОСЬ  строка автообновления в $CRONTAB"
	left=1
fi

# Демоны. Пакета уже нет, так что живой nfqws2 — это осиротевший процесс.
if command -v pidof >/dev/null 2>&1 && pidof nfqws2 >/dev/null 2>&1; then
	echo "ОСТАЛОСЬ  работающий nfqws2 (pid: $(pidof nfqws2))"
	echo "          погасить: killall nfqws2"
	left=1
fi

# Правила netfilter. Не удаляем их вслепую: чужие правила по маске зацепить
# легко, а последствия на роутере дороже, чем ручной шаг.
if command -v iptables-save >/dev/null 2>&1; then
	n=$(iptables-save -t mangle 2>/dev/null | grep -c NFQUEUE || true)
	[ -n "$n" ] || n=0
	if [ "$n" != 0 ]; then
		echo "ОСТАЛОСЬ  правил NFQUEUE в mangle: $n"
		echo "          посмотреть: iptables-save -t mangle | grep NFQUEUE"
		left=1
	fi
	m=$(iptables-save -t nat 2>/dev/null | grep -c -- "$DESYNC_MARK" || true)
	[ -n "$m" ] || m=0
	if [ "$m" != 0 ]; then
		echo "ОСТАЛОСЬ  правил MASQUERADE с меткой $DESYNC_MARK в nat: $m"
		echo "          посмотреть: iptables-save -t nat | grep $DESYNC_MARK"
		left=1
	fi
fi

echo
if [ "$left" = 0 ]; then
	msg "откат завершён, следов не осталось"
	if [ "$KEEP_CONFIG" = 1 ]; then
		msg "настройки сохранены в $ZAPRET_RW_DIR"
	fi
	exit 0
fi

warn "кое-что осталось — см. строки ОСТАЛОСЬ выше."
warn "Правила netfilter Keenetic пересобирает сам при смене состояния WAN или"
warn "перезагрузке, так что после reboot их почти наверняка не будет."
exit 1
