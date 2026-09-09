#!/bin/sh
# Согласованность конфига, conffiles и путей: тут ловятся опечатки, из-за которых
# пакет собрался бы, установился и молча не работал.
. "$(dirname "$0")/../lib.sh"

CFG="$ROOT/package/root/opt/etc/zapret2/config"
INIT="$ROOT/package/root/opt/etc/init.d/S99zapret2"
HOOK="$ROOT/package/root/opt/etc/ndm/netfilter.d/50-zapret2.sh"
UDPFIX="$ROOT/package/root/opt/etc/zapret2/custom.d/10-keenetic-udp-fix"

# --- значения, без которых zapret на Keenetic не работает ---------------------
# читаем конфиг так же, как это делает init-скрипт
val() { ( . "$CFG"; eval "printf '%s' \"\$$1\"" ); }

assert_eq "nobody"   "$(val WS_USER)"     "WS_USER=nobody: юзер должен быть из /etc/passwd прошивки"
assert_eq "iptables" "$(val FWTYPE)"      "FWTYPE=iptables: nftables на Keenetic нет"
assert_eq "1"        "$(val NFQWS2_ENABLE)" "NFQWS2_ENABLE=1: иначе демон не запустится вообще"
assert_eq "1"        "$(val INIT_APPLY_FW)" "INIT_APPLY_FW=1: правила ставит init-скрипт"
assert_ne ""         "$(val NFQWS2_OPT)"  "NFQWS2_OPT не пустой"
assert_ne ""         "$(val DESYNC_MARK)" "DESYNC_MARK задан: на него опирается udp-фикс"

# HOSTLIST_BASE обязан совпадать с IPSET_RW_DIR=$ZAPRET_RW/ipset из ipset/def.sh,
# иначе nfqws и скрипты получения списков смотрят в разные каталоги
assert_eq "/opt/etc/zapret2/ipset" "$(val HOSTLIST_BASE)" "HOSTLIST_BASE совпадает с ZAPRET_RW/ipset"

# --- conffiles описывают существующие файлы -----------------------------------
while IFS= read -r cf; do
	[ -n "$cf" ] || continue
	assert_file "$ROOT/package/root$cf" "conffile $cf есть в дереве пакета"
done <"$ROOT/package/control/conffiles"

# --- пути, которыми файлы ссылаются друг на друга ------------------------------
assert_grep "/opt/etc/init.d/S99zapret2" "$HOOK"  "хук ndm зовёт init по правильному пути"
assert_grep "reapply" "$HOOK"                     "хук ndm зовёт именно reapply"
assert_grep "S99zapret2" "$ROOT/package/root/opt/bin/zapret2" "обёртка /opt/bin/zapret2 указывает на init"
assert_grep "ZAPRET_RW:-/opt/etc/zapret2" "$INIT" "init-скрипт кладёт r/w часть в /opt/etc/zapret2"
assert_grep "ZAPRET_BASE:-/opt/zapret2" "$INIT"   "init-скрипт ищет upstream в /opt/zapret2"

# --- фикс UDP делает то, ради чего он есть ------------------------------------
assert_grep "MASQUERADE"  "$UDPFIX" "udp-фикс добавляет MASQUERADE"
assert_grep "DESYNC_MARK" "$UDPFIX" "udp-фикс отбирает пакеты по DESYNC_MARK"
assert_grep "zapret_custom_firewall" "$UDPFIX" "udp-фикс объявляет хук, который зовёт custom_runner"

# custom.d должен лежать там, где init-скрипт выставляет CUSTOM_DIR
assert_grep 'CUSTOM_DIR="\$ZAPRET_RW"' "$INIT" "CUSTOM_DIR указывает на ZAPRET_RW (то есть ZAPRET_RW/custom.d)"
assert_file "$ROOT/package/root/opt/etc/zapret2/custom.d/10-keenetic-udp-fix" "udp-фикс лежит в custom.d"

# --- шаблон control заполняется целиком ---------------------------------------
for ph in PKG_NAME PKG_VERSION PKG_ARCH PKG_DEPENDS PKG_SECTION PKG_PRIORITY PKG_MAINTAINER PKG_HOMEPAGE; do
	assert_grep "@$ph@" "$ROOT/package/control/control.tmpl" "в шаблоне control есть плейсхолдер @$ph@"
	assert_grep "@$ph@" "$ROOT/scripts/mkipk.sh" "mkipk.sh подставляет @$ph@"
done

finish
