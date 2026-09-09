#!/bin/sh
#
# Хук ndm: Keenetic периодически пересобирает netfilter (смена состояния WAN,
# перезапуск firewall, работа встроенных сервисов) и при этом вычищает чужие
# правила. Без этого хука правила zapret2 «слетают» каждые несколько минут.
#
# ndm вызывает скрипты из /opt/etc/ndm/netfilter.d/ с переменными окружения:
#   type  - iptables | ip6tables | ebtables
#   table - имя таблицы, которую ndm перестраивал
#
# Мы не переставляем правила синхронно: ndm дёргает хук пачкой по десятку раз
# подряд, а полная переустановка правил дорогая. Вместо этого просим init-скрипт
# запланировать одну отложенную переустановку (он сам коалесцирует вызовы).

INIT=${ZAPRET_INIT:-/opt/etc/init.d/S99zapret2}

# ebtables нас не касается
[ "$type" = "ebtables" ] && exit 0

# Сервис не запущен — переставлять нечего. Метку ищем там же, где её кладёт
# init-скрипт: /var/run, а если он не пишется — /tmp (ZAPRET_RUNDIR — для тестов).
started=
for d in ${ZAPRET_RUNDIR:-} /var/run /tmp; do
	[ -f "$d/zapret2.started" ] && { started=1; break; }
done
[ -n "$started" ] || exit 0

[ -x "$INIT" ] || exit 0

"$INIT" reapply >/dev/null 2>&1

exit 0
