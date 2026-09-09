# shellcheck shell=sh
# Общие определения для сборочных скриптов пакета zapret2 под Keenetic (Entware).
# Подключается всеми scripts/*.sh, самостоятельно не запускается.
#
# Переменные ниже потребляют подключающие скрипты, а не сама библиотека.
# shellcheck disable=SC2034

PKG_NAME=zapret2
PKG_SECTION=net
PKG_PRIORITY=optional
PKG_MAINTAINER="operationka <akuznetsov.ekt@icloud.com>"
PKG_HOMEPAGE="https://github.com/bol-van/zapret2"

UPSTREAM_REPO=${UPSTREAM_REPO:-https://github.com/bol-van/zapret2}
MUSL_CROSS_REPO=${MUSL_CROSS_REPO:-https://github.com/bol-van/musl-cross}

# Пути на роутере
INSTALL_PREFIX=/opt
ZAPRET_BASE=/opt/zapret2
ZAPRET_RW=/opt/etc/zapret2

die()  { echo "ERROR: $*" >&2; exit 1; }
msg()  { echo "==> $*" >&2; }
warn() { echo "WARN: $*" >&2; }

need() {
	for _c in "$@"; do
		command -v "$_c" >/dev/null 2>&1 || die "не найдена утилита '$_c' — поставь её на сборочной машине"
	done
}

# Список поддерживаемых Entware-архитектур
arch_list() { echo "mipsel-3.4 aarch64-3.10 armv7-3.2"; }

# Entware arch -> каталог binaries/<dir> в релизном тарболе zapret2
arch_bindir() {
	case "$1" in
		mipsel-3.4)   echo linux-mipsel ;;
		aarch64-3.10) echo linux-arm64  ;;
		armv7-3.2)    echo linux-arm    ;;
		*) return 1 ;;
	esac
}

# Entware arch -> имя арки в CI zapret2 (артефакты zapret2-linux-<arch>.tar.xz)
arch_ci() {
	case "$1" in
		mipsel-3.4)   echo mipselsf ;;
		aarch64-3.10) echo arm64    ;;
		armv7-3.2)    echo arm      ;;
		*) return 1 ;;
	esac
}

# Entware arch -> triplet тулчейна из bol-van/musl-cross
arch_toolchain() {
	case "$1" in
		mipsel-3.4)   echo mipsel-unknown-linux-muslsf ;;
		aarch64-3.10) echo aarch64-unknown-linux-musl  ;;
		armv7-3.2)    echo armv6-unknown-linux-musleabi ;;
		*) return 1 ;;
	esac
}

# Дополнительные CFLAGS под конкретную арку (взяты из .github/workflows/build.yml zapret2)
arch_cpuflags() {
	case "$1" in
		armv7-3.2) echo "-mcpu=arm1176jzf-s -mthumb" ;;
		*) echo "" ;;
	esac
}

# luajit собирается с системным malloc везде, кроме 64-битных целей (там небезопасно без GC64)
arch_luajit_sysmalloc() {
	case "$1" in
		aarch64-3.10) echo "" ;;
		*) echo "-DLUAJIT_USE_SYSMALLOC" ;;
	esac
}

arch_check() {
	arch_bindir "$1" >/dev/null 2>&1 || die "неизвестная архитектура '$1'. Поддерживаются: $(arch_list)"
}

# Версия пакета: <версия zapret2 без 'v'>-<ревизия пакета>
pkg_version() {
	# $1 - upstream ref (v1.0.5.1 / 1.0.5.1)
	printf '%s-%s\n' "${1#v}" "${PKG_REVISION:-1}"
}

ipk_filename() {
	# $1 - upstream ref, $2 - arch
	printf '%s_%s_%s.ipk\n' "$PKG_NAME" "$(pkg_version "$1")" "$2"
}

# Entware arch -> ожидаемые поля ELF-заголовка: "EI_CLASS EI_DATA e_machine"
# EI_CLASS: 1=32bit, 2=64bit; EI_DATA: 1=LE, 2=BE; e_machine: 8=MIPS, 40=ARM, 183=AArch64
arch_elf() {
	case "$1" in
		mipsel-3.4)   echo "1 1 8"   ;;
		aarch64-3.10) echo "2 1 183" ;;
		armv7-3.2)    echo "1 1 40"  ;;
		*) return 1 ;;
	esac
}

# Читает один байт ELF-заголовка: elf_byte <файл> <смещение>
elf_byte() { od -An -tu1 -j"$2" -N1 "$1" 2>/dev/null | tr -d ' \n'; }

# Читает e_machine с учётом порядка байт: elf_machine <файл>
elf_machine() {
	local d b0 b1
	d=$(elf_byte "$1" 5)
	b0=$(elf_byte "$1" 18)
	b1=$(elf_byte "$1" 19)
	[ -n "$b0" ] && [ -n "$b1" ] || return 1
	if [ "$d" = 2 ]; then echo $((b0 * 256 + b1)); else echo $((b1 * 256 + b0)); fi
}
