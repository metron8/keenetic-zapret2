#!/bin/sh
# Оркестрация сборки: Makefile должен пересобирать пакет при смене источника
# бинарников и уметь пройти весь путь до .ipk офлайн.
. "$(dirname "$0")/../lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

mk() { make -C "$ROOT" --no-print-directory "$@" 2>/dev/null; }

# --- РЕГРЕССИЯ: каталог бинарников зависит от источника -----------------------
# Раньше .stamp лежал в build/bin/<арх> без учёта BINSRC, поэтому после сборки из
# релиза команда `make ipk BINSRC=source` молча переупаковывала скачанные бинарники,
# и make inspect этого не замечал.
rel=$(mk print-BINOUT BINSRC=release)
src=$(mk print-BINOUT BINSRC=source)
assert_ne "$rel" "$src" "BINSRC=release и BINSRC=source кладут бинарники в разные каталоги"

a=$(mk print-BINOUT BINSRC=local BINDIR=/tmp/a)
b=$(mk print-BINOUT BINSRC=local BINDIR=/tmp/b)
assert_ne "$a" "$b" "разные BINDIR при BINSRC=local не переиспользуют чужой .stamp"

# --- сквозная офлайн-сборка через make ----------------------------------------
# Подкладываем синтетическое дерево upstream вместо клона, чтобы не ходить в сеть.
repo="$TMP/repo"
cp -a "$ROOT" "$repo"
rm -rf "$repo/build" "$repo/dist" "$repo/.git"

REF=vtest
# Ревизию задаём явно: тест не должен зависеть от того, какой PKG_REVISION
# сейчас стоит в Makefile — он меняется при каждом релизе.
REV=1
make_fake_upstream "$repo/build/src/$REF"
touch "$repo/build/src/$REF/.stamp"

bin="$TMP/bin"; mkdir -p "$bin"
for f in nfqws2 mdig ip2net; do make_stub_elf mipsel-3.4 "$bin/$f"; done

if out=$(make -C "$repo" --no-print-directory ipk REF="$REF" PKG_REVISION="$REV" ARCH=mipsel-3.4 \
              BINSRC=local BINDIR="$bin" 2>&1); then
	ok "make ipk проходит офлайн от дерева до пакета"
else
	bad "make ipk упал"
	echo "$out" | sed 's/^/        /'
fi
assert_file "$repo/dist/zapret2_test-${REV}_mipsel-3.4.ipk" "пакет лёг в dist с ожидаемым именем"

if out=$(make -C "$repo" --no-print-directory inspect REF="$REF" PKG_REVISION="$REV" ARCH=mipsel-3.4 \
              BINSRC=local BINDIR="$bin" 2>&1); then
	ok "make inspect принимает собранный пакет"
else
	bad "make inspect забраковал собранный пакет"
	echo "$out" | sed 's/^/        /'
fi

# смена источника обязана привести к пересборке, а не переиспользованию
bin2="$TMP/bin2"; mkdir -p "$bin2"
for f in nfqws2 mdig ip2net; do make_stub_elf aarch64-3.10 "$bin2/$f"; done
make -C "$repo" --no-print-directory ipk REF="$REF" PKG_REVISION="$REV" ARCH=aarch64-3.10 \
     BINSRC=local BINDIR="$bin2" >/dev/null 2>&1
if make -C "$repo" --no-print-directory inspect REF="$REF" PKG_REVISION="$REV" ARCH=aarch64-3.10 \
        BINSRC=local BINDIR="$bin2" >/dev/null 2>&1; then
	ok "вторая арка собирается и проходит проверку рядом с первой"
else
	bad "вторая арка не прошла проверку — похоже, переиспользованы чужие бинарники"
fi

# --- make check и help не должны падать ---------------------------------------
assert_status 0 make -C "$repo" --no-print-directory check
assert_status 0 make -C "$repo" --no-print-directory help

# --- clean убирает артефакты, но не исходники ---------------------------------
make -C "$repo" --no-print-directory clean >/dev/null 2>&1
assert_nofile "$repo/dist/zapret2_test-${REV}_mipsel-3.4.ipk" "clean убирает dist"
assert_file "$repo/build/src/$REF/config.default" "clean не трогает выкачанные исходники"

finish
