#!/bin/sh
# Версия релиза задана в Makefile (REF + PKG_REVISION), но install.sh вшивает её
# у себя: он standalone-скрипт, ему неоткуда её взять. Значит два места могут
# разъехаться — и однажды уже разъехались, из-за чего install.sh тянул бы пакет
# предыдущего релиза. Этот тест сторожит их совпадение.
. "$(dirname "$0")/../lib.sh"

REF=$(make -C "$ROOT" --no-print-directory print-REF)
REV=$(make -C "$ROOT" --no-print-directory print-PKG_REVISION)
WANT="v${REF#v}-$REV"

GOT=$(sed -n 's/^TAG=//p' "$ROOT/install.sh" | head -n1)

assert_eq "$WANT" "$GOT" "TAG в install.sh совпадает с REF+PKG_REVISION из Makefile"

# Формат тега разбирает release.yml: v<версия>-<ревизия>. Если он перестанет
# соответствовать, релиз соберётся с неверной версией пакета.
case "$WANT" in
	v*-*) ok "тег имеет вид v<версия>-<ревизия>" ;;
	*)    bad "тег «$WANT» не имеет вида v<версия>-<ревизия>" ;;
esac

# Та же версия должна получаться и у сборочных скриптов.
VER=$(cd "$ROOT" && . scripts/lib.sh && PKG_REVISION="$REV" pkg_version "$REF")
assert_eq "${WANT#v}" "$VER" "pkg_version из lib.sh даёт ту же версию"

finish
