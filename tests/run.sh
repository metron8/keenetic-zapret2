#!/bin/sh
# Прогон всех тестов. Полностью офлайн: сеть не нужна, роутер не нужен.
#
#   tests/run.sh            # все тесты
#   tests/run.sh 050        # только те, чьё имя содержит 050
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
FILTER=${1:-}

total=0
failed=0
failed_names=

for t in "$HERE"/t/*.sh; do
	name=$(basename "$t")
	case "$name" in
		*"$FILTER"*) ;;
		*) continue ;;
	esac
	total=$((total + 1))
	echo "== $name"
	if sh "$t"; then
		:
	else
		failed=$((failed + 1))
		failed_names="$failed_names $name"
	fi
done

echo
if [ "$failed" = 0 ]; then
	echo "ВСЕ ТЕСТЫ ПРОШЛИ ($total файлов)"
	exit 0
fi
echo "ПАДЕНИЯ ($failed из $total):$failed_names"
exit 1
