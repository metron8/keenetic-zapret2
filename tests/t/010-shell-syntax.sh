#!/bin/sh
# Всё, что уезжает на роутер или запускается при сборке, должно парситься /bin/sh.
. "$(dirname "$0")/../lib.sh"

for f in "$ROOT"/scripts/*.sh \
         "$ROOT"/tests/run.sh "$ROOT"/tests/lib.sh "$ROOT"/tests/t/*.sh \
         "$ROOT"/package/control/postinst "$ROOT"/package/control/prerm "$ROOT"/package/control/postrm \
         "$ROOT"/package/root/opt/etc/init.d/S99zapret2 \
         "$ROOT"/package/root/opt/etc/ndm/netfilter.d/*.sh \
         "$ROOT"/package/root/opt/bin/* \
         "$ROOT"/package/root/opt/etc/zapret2/config \
         "$ROOT"/package/root/opt/etc/zapret2/custom.d/*; do
	[ -f "$f" ] || continue
	if sh -n "$f" 2>/dev/null; then
		ok "парсится: ${f#$ROOT/}"
	else
		bad "не парсится: ${f#$ROOT/}"
	fi
done

# Файлы, которые ставятся исполняемыми, должны быть исполняемыми и в репозитории:
# git хранит бит, а stage.sh на него полагается.
for f in package/root/opt/etc/init.d/S99zapret2 \
         package/root/opt/etc/ndm/netfilter.d/50-zapret2.sh \
         package/root/opt/bin/zapret2 package/root/opt/bin/zapret2-list \
         scripts/stage.sh scripts/mkipk.sh scripts/inspect-ipk.sh \
         scripts/fetch-source.sh scripts/fetch-binaries.sh scripts/build-binaries.sh \
         tests/run.sh; do
	if [ -x "$ROOT/$f" ]; then ok "исполняемый: $f"; else bad "не исполняемый: $f"; fi
done

finish
