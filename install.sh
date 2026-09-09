#!/bin/sh
# Установка zapret2 на роутер Keenetic (Entware) с минимальным вмешательством.
#
# Запускать НА РОУТЕРЕ, под root:
#   curl -fL -o /opt/tmp/install.sh https://raw.githubusercontent.com/metron8/keenetic-zapret2/main/install.sh
#   sh /opt/tmp/install.sh
#
# Что делает:
#   1. определяет архитектуру через opkg print-architecture;
#   2. качает .ipk нужной арки из релиза и сверяет sha256 по sha256sum.txt оттуда же;
#   3. ставит пакет через opkg;
#   4. прописывает IFACE_WAN в конфиг, если он ещё не задан (автоопределение по
#      маршруту по умолчанию — ровно так же, как это делает сам пакет);
#   5. скачивает список доменов и включает MODE_FILTER=autohostlist;
#   6. прогоняет `zapret2 check`;
#   7. запускает сервис ТОЛЬКО если check прошёл без ошибок.
#
# Стратегию обхода (NFQWS2_OPT) скрипт не подбирает: это делает blockcheck2 на
# самом роутере и это долго. Скрипт напомнит про него в конце.
#
# Ключи: см. `sh install.sh --help`.

set -e

# --- настройки по умолчанию ---------------------------------------------------

REPO=metron8/keenetic-zapret2
# Тег релиза, из которого ставим. Должен совпадать с REF+PKG_REVISION в Makefile —
# это сторожит тест t/120-version-consistency.sh. Переопределяется ключом --tag.
TAG=v1.0.5.1-3

# Переопределяются только тестами; в бою пусты/дефолтны.
PREFIX=${ZAPRET_ROOT_PREFIX:-}
BASEURL=${ZAPRET_INSTALL_BASE:-https://github.com/$REPO/releases/download}
ROUTE_FILE=${ZAPRET_ROUTE_FILE:-/proc/net/route}

ARCH=
IFACE=
IPK=
START_MODE=auto   # auto | never | always
VERIFY=1
FORCE=0
WANT_LISTS=1
WANT_CRON=1
LIST_MODE=autohostlist
# Берём именно этот скрипт: он скачивает доменный список ПЕРВЫМ делом и лишь
# потом трогает ipset. У get_refilter_domains.sh и get_antizapret_domains.sh
# порядок обратный — на роутере без компонента IPset они выйдут, не скачав
# ничего.
LIST_SCRIPT=get_reestr_resolvable_domains.sh

CONFIG=$PREFIX/opt/etc/zapret2/config
ZAPRET_BIN=$PREFIX/opt/bin/zapret2
ZAPRET_LIST_BIN=$PREFIX/opt/bin/zapret2-list
TMPDIR_R=$PREFIX/opt/tmp

msg()  { echo "==> $*"; }
warn() { echo "ВНИМАНИЕ: $*" >&2; }
die()  { echo "ОШИБКА: $*" >&2; exit 1; }

usage()
{
	cat <<'USAGE'
Установка zapret2 на Keenetic (Entware). Запускать на роутере под root.

  sh install.sh [ключи]

Ключи:
  --arch=ARCH     не определять архитектуру, взять эту (mipsel-3.4 | aarch64-3.10)
  --iface=IFACE   не определять WAN, вписать этот интерфейс (ppp0, eth3, nwg0 ...)
  --tag=TAG       ставить из этого релиза (по умолчанию встроенный в скрипт)
  --ipk=PATH      взять готовый .ipk с диска, ничего не качать
  --no-lists      не качать список доменов, оставить MODE_FILTER=none
  --lists=SCRIPT  качать другим скриптом (см. zapret2-list --list)
  --hostlist      режим hostlist: только скачанный список, без самопополнения
  --no-cron       не добавлять автообновление списка в cron
  --no-start      не запускать сервис вообще, только поставить и настроить
  --force-start   запускать даже если `zapret2 check` нашёл проблемы
  --no-verify     не сверять sha256 скачанного пакета (не надо так)
  --force         переустановить, даже если стоит та же версия
  -h, --help      это сообщение

По умолчанию сервис запускается, только если `zapret2 check` прошёл чисто.
По умолчанию скачивается список доменов и включается MODE_FILTER=autohostlist:
скачанный список плюс самопополнение по признакам блокировки.
Если список скачать не удалось, режим остаётся none — так обход работает сразу
и по всему трафику, а не по мере доучивания.
USAGE
}

# --- разбор аргументов --------------------------------------------------------

for a in "$@"; do
	case "$a" in
		--arch=*)     ARCH=${a#--arch=} ;;
		--iface=*)    IFACE=${a#--iface=} ;;
		--tag=*)      TAG=${a#--tag=} ;;
		--ipk=*)      IPK=${a#--ipk=} ;;
		--no-lists)   WANT_LISTS=0 ;;
		--lists=*)    LIST_SCRIPT=${a#--lists=} ;;
		--hostlist)   LIST_MODE=hostlist ;;
		--no-cron)    WANT_CRON=0 ;;
		--no-start)   START_MODE=never ;;
		--force-start) START_MODE=always ;;
		--no-verify)  VERIFY=0 ;;
		--force)      FORCE=1 ;;
		-h|--help)    usage; exit 0 ;;
		*)            usage >&2; die "неизвестный ключ: $a" ;;
	esac
done

# --- предполётные проверки ----------------------------------------------------

# С ZAPRET_ROOT_PREFIX (только тесты) живую систему не трогаем — root не нужен,
# ровно как maintainer-скрипты не трогают систему под IPKG_INSTROOT.
if [ -z "$PREFIX" ] && [ "$(id -u)" != 0 ]; then
	die "нужны права root — зайди на роутер как root"
fi

command -v opkg >/dev/null 2>&1 || die "не найден opkg. Entware не установлена или /opt не смонтирован"

DL=
if command -v curl >/dev/null 2>&1; then
	DL=curl
elif command -v wget >/dev/null 2>&1; then
	DL=wget
fi

dl()
{
	# $1 - url, $2 - куда положить
	case "$DL" in
		curl) curl -fL --retry 2 -o "$2" "$1" ;;
		wget) wget -q -O "$2" "$1" ;;
		*)    die "нужен curl или wget, чтобы скачать пакет (или поставь с диска: --ipk=PATH)" ;;
	esac
}

# --- архитектура --------------------------------------------------------------

detect_arch()
{
	for _a in $(opkg print-architecture 2>/dev/null | awk '{print $2}'); do
		case "$_a" in
			mipsel-3.4|aarch64-3.10) echo "$_a"; return 0 ;;
		esac
	done
	return 1
}

if [ -z "$ARCH" ]; then
	ARCH=$(detect_arch) || die "не удалось определить архитектуру.
     opkg print-architecture не показал ни mipsel-3.4, ни aarch64-3.10.
     Задай явно: --arch=mipsel-3.4"
fi
case "$ARCH" in
	mipsel-3.4|aarch64-3.10) ;;
	*) die "архитектура '$ARCH' не поддерживается. Есть mipsel-3.4 и aarch64-3.10" ;;
esac
msg "архитектура: $ARCH"

# --- уже установлено? ---------------------------------------------------------

INSTALLED=$(opkg list-installed zapret2 2>/dev/null | awk '{print $3}' | head -n1)
WANT_VERSION=${TAG#v}
if [ -n "$INSTALLED" ]; then
	msg "уже установлен zapret2 $INSTALLED"
	if [ "$INSTALLED" = "$WANT_VERSION" ] && [ "$FORCE" = 0 ]; then
		msg "та же версия — пропускаю установку (переустановить: --force)"
		SKIP_INSTALL=1
	fi
fi
SKIP_INSTALL=${SKIP_INSTALL:-0}

# --- получение пакета ---------------------------------------------------------

PKGFILE=zapret2_${WANT_VERSION}_${ARCH}.ipk

if [ "$SKIP_INSTALL" = 0 ]; then
	if [ -n "$IPK" ]; then
		[ -f "$IPK" ] || die "нет файла $IPK"
		msg "ставлю из $IPK, загрузка и сверка сумм пропущены"
	else
		mkdir -p "$TMPDIR_R"
		IPK=$TMPDIR_R/$PKGFILE
		msg "качаю $BASEURL/$TAG/$PKGFILE"
		dl "$BASEURL/$TAG/$PKGFILE" "$IPK" ||
			die "не скачался пакет. Проверь, что релиз '$TAG' существует и есть выход в сеть"

		if [ "$VERIFY" = 1 ]; then
			command -v sha256sum >/dev/null 2>&1 ||
				die "нет sha256sum, нечем сверить пакет. Пропустить проверку: --no-verify"
			msg "сверяю контрольную сумму"
			dl "$BASEURL/$TAG/sha256sum.txt" "$TMPDIR_R/sha256sum.txt" ||
				die "не скачался sha256sum.txt — не могу проверить пакет.
     Если готов рискнуть: --no-verify"

			# Сравниваем имена точной строкой, а не регуляркой: в именах файлов есть точки.
			want=
			while read -r h n; do
				n=${n#./}
				if [ "$n" = "$PKGFILE" ]; then want=$h; break; fi
			done <"$TMPDIR_R/sha256sum.txt"
			[ -n "$want" ] || die "в sha256sum.txt нет записи для $PKGFILE"

			got=$(sha256sum "$IPK" | awk '{print $1}')
			if [ "$want" != "$got" ]; then
				rm -f "$IPK"
				die "контрольная сумма не сошлась.
     ожидалась $want
     получена  $got
     Файл удалён. Скачай заново или проверь, не подменяет ли кто трафик."
			fi
			msg "sha256 совпала"
		else
			warn "сверка sha256 отключена ключом --no-verify"
		fi
	fi

	# postinst пакета тоже умеет наполнять список, но у install.sh свои ключи
	# (--lists/--autohostlist/--no-lists), поэтому там его глушим и делаем это
	# ниже сами. Иначе список качался бы дважды.
	msg "ставлю пакет"
	if [ "$FORCE" = 1 ] && [ -n "$INSTALLED" ]; then
		ZAPRET_NO_LISTS=1 opkg install --force-reinstall "$IPK"
	else
		ZAPRET_NO_LISTS=1 opkg install "$IPK"
	fi
fi

[ -f "$CONFIG" ] || die "после установки нет конфига $CONFIG — установка не удалась"

# --- правка конфига -----------------------------------------------------------

# Активная (не закомментированная) строка переменной есть?
config_has() { grep -q "^[[:space:]]*$1=" "$CONFIG"; }
config_get() { sed -n "s/^[[:space:]]*$1=//p" "$CONFIG" | head -n1; }

# Бэкап делаем один раз, перед первой правкой: иначе вторая правка затёрла бы
# оригинал уже изменённым конфигом.
config_backup()
{
	if [ ! -f "$CONFIG.bak" ]; then
		cp "$CONFIG" "$CONFIG.bak"
		msg "прежний конфиг сохранён в $CONFIG.bak"
	fi
}

config_set()
{
	# $1 - имя переменной, $2 - значение
	config_backup
	if config_has "$1"; then
		sed "s|^[[:space:]]*$1=.*|$1=$2|" "$CONFIG" >"$CONFIG.new"
	elif grep -q "^#$1=" "$CONFIG"; then
		sed "s|^#$1=.*|$1=$2|" "$CONFIG" >"$CONFIG.new"
	else
		{ cat "$CONFIG"; printf '\n%s=%s\n' "$1" "$2"; } >"$CONFIG.new"
	fi
	mv "$CONFIG.new" "$CONFIG"
	msg "в конфиг вписано $1=$2"
}

# --- WAN-интерфейс ------------------------------------------------------------

# Тот же разбор /proc/net/route, что и в самом пакете: строки с маской 00000000.
detect_iface()
{
	sed -nre 's/^([^\t]+)\t00000000\t[0-9A-F]{8}\t[0-9A-F]{4}\t[0-9]+\t[0-9]+\t[0-9]+\t00000000.*$/\1/p' \
		"$ROUTE_FILE" 2>/dev/null | sort -u | xargs
}

if config_has IFACE_WAN; then
	msg "IFACE_WAN уже задан в конфиге, не трогаю: $(config_get IFACE_WAN)"
else
	if [ -z "$IFACE" ]; then
		IFACE=$(detect_iface)
		case "$IFACE" in
			"")   die "не удалось определить WAN-интерфейс по $ROUTE_FILE.
     Задай явно: --iface=ppp0 (PPPoE) или --iface=eth3 (IPoE)" ;;
			*" "*) die "маршрут по умолчанию ведёт сразу через несколько интерфейсов: $IFACE
     Выбери нужный сам: --iface=<один из них>" ;;
		esac
		msg "WAN-интерфейс определён автоматически: $IFACE"
	else
		msg "WAN-интерфейс задан ключом: $IFACE"
	fi
	config_set IFACE_WAN "$IFACE"
fi

# --- списки доменов -----------------------------------------------------------

# Саму загрузку и переключение режима делает `zapret2-list --bootstrap` из
# пакета: там же это нужно postinst'у при ручной установке через opkg, и
# дублировать логику в двух местах — верный способ развести их поведение.
if [ "$WANT_LISTS" = 0 ]; then
	msg "загрузка списков пропущена (--no-lists), MODE_FILTER=$(config_get MODE_FILTER)"
elif [ ! -x "$ZAPRET_LIST_BIN" ]; then
	warn "нет $ZAPRET_LIST_BIN — список не скачать, остаётся MODE_FILTER=none"
else
	ZAPRET_BASE="$PREFIX/opt/zapret2" ZAPRET_RW="$PREFIX/opt/etc/zapret2" \
	ZAPRET_CRONTAB="$PREFIX/opt/etc/crontabs/root" \
	ZAPRET_BOOTSTRAP_SCRIPT="$LIST_SCRIPT" ZAPRET_BOOTSTRAP_MODE="$LIST_MODE" \
		"$ZAPRET_LIST_BIN" --bootstrap || true
	if [ "$WANT_CRON" = 0 ]; then
		ZAPRET_CRONTAB="$PREFIX/opt/etc/crontabs/root" \
			"$ZAPRET_LIST_BIN" --cron off >/dev/null 2>&1 || true
		msg "автообновление списка не добавлено (--no-cron)"
	fi
fi

# --- диагностика --------------------------------------------------------------

[ -x "$ZAPRET_BIN" ] || die "нет $ZAPRET_BIN — пакет установлен не полностью"

msg "проверяю предпосылки (zapret2 check)"
echo
if "$ZAPRET_BIN" check; then
	CHECK_OK=1
else
	CHECK_OK=0
fi
echo

# --- запуск -------------------------------------------------------------------

started=0
case "$START_MODE" in
	never)
		msg "запуск пропущен (--no-start)"
		;;
	always)
		[ "$CHECK_OK" = 1 ] || warn "check нашёл проблемы, но запускаю из-за --force-start"
		"$ZAPRET_BIN" start
		started=1
		;;
	auto)
		if [ "$CHECK_OK" = 1 ]; then
			msg "предпосылки в порядке — запускаю"
			"$ZAPRET_BIN" start
			started=1
		else
			warn "check нашёл проблемы — сервис НЕ запущен."
			warn "Разбери вывод выше, почини и запусти вручную: zapret2 start"
			warn "Либо, если уверен: sh install.sh --force-start"
		fi
		;;
esac

if [ "$started" = 1 ]; then
	echo
	msg "состояние после запуска:"
	if "$ZAPRET_BIN" status; then
		echo
		msg "готово. Демоны подняты, правила стоят."
	else
		echo
		warn "сервис запущен, но status недоволен — разбери его вывод выше."
		warn "Чаще всего это «правил NFQUEUE: 0»: правила снёс ndm."
		warn "Попробуй: zapret2 restart-fw"
	fi
fi

# --- что дальше ---------------------------------------------------------------

cat <<NEXT

--- дальше ---
1. Проверь на устройстве за роутером, открывается ли то, что не открывалось.
2. Если нужного домена нет в списке — допиши руками:
     vi /opt/etc/zapret2/ipset/zapret-hosts-user.txt   # по домену в строке
     zapret2 restart
   Обновить скачанный список позже:  zapret2-list
3. Если не открывается вообще ничего из заблокированного — стратегия обхода не
   подошла провайдеру. Подбери свою:
     ZAPRET_BASE=/opt/zapret2 ZAPRET_RW=/opt/etc/zapret2 sh /opt/zapret2/blockcheck2.sh
   и впиши результат в NFQWS2_OPT в $CONFIG, затем: zapret2 restart
4. Через 10 минут проверь, что правила не слетели: zapret2 status
   Число правил NFQUEUE должно остаться больше нуля — за это отвечает хук ndm.
5. Откат, если что-то не так:  zapret2 stop   либо   opkg remove zapret2

NEXT

if [ "$CHECK_OK" = 1 ]; then
	exit 0
fi
exit 1
