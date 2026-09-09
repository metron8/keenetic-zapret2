#!/bin/sh
# Прогон линтера, если он установлен. В CI он есть всегда, локально — как повезёт.
. "$(dirname "$0")/../lib.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "    -- shellcheck не установлен, пропускаю"
	exit 0
fi

# SC1090/SC1091 - динамические source, их пути известны только на роутере
# SC2059 - printf с переменной в формате: в make_stub_elf это намеренно
# SC3043 - 'local' вне POSIX. На роутере это busybox ash, на сборочной машине
#          dash/bash — 'local' есть везде, upstream zapret2 сам им пользуется
EXCLUDE=SC1090,SC1091,SC2059,SC3043

for f in "$ROOT"/install.sh "$ROOT"/scripts/*.sh \
         "$ROOT"/tests/run.sh "$ROOT"/tests/lib.sh "$ROOT"/tests/t/*.sh \
         "$ROOT"/package/control/postinst "$ROOT"/package/control/prerm "$ROOT"/package/control/postrm \
         "$ROOT"/package/root/opt/etc/init.d/S99zapret2 \
         "$ROOT"/package/root/opt/etc/ndm/netfilter.d/*.sh \
         "$ROOT"/package/root/opt/bin/zapret2 "$ROOT"/package/root/opt/bin/zapret2-list; do
	[ -f "$f" ] || continue
	if out=$(shellcheck -s sh -e "$EXCLUDE" "$f" 2>&1); then
		ok "shellcheck: ${f#"$ROOT"/}"
	else
		bad "shellcheck: ${f#"$ROOT"/}"
		echo "$out" | sed 's/^/        /'
	fi
done

finish
