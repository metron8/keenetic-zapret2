# Сборка .ipk пакета zapret2 для Keenetic (Entware).
#
#   make ipk ARCH=mipsel-3.4                # готовые бинарники из релиза upstream
#   make ipk ARCH=aarch64-3.10 BINSRC=source  # кросс-сборка из исходников
#   make ipk-all                            # все поддерживаемые архитектуры
#   make inspect ARCH=mipsel-3.4            # проверить собранный пакет
#   make help

SHELL := /bin/sh

# Версия zapret2, из которой собираем пакет (git-тег upstream).
REF ?= v1.0.5.1
# Ревизия самого пакета: меняй, если пересобираешь ту же версию zapret2.
# Это единственный источник версии для релиза: подними — и CI выпустит тег.
PKG_REVISION ?= 2
# Архитектура Entware. Список: make archs
ARCH ?= mipsel-3.4
ARCHS := mipsel-3.4 aarch64-3.10
# Откуда брать nfqws2/mdig/ip2net: release | source | local
BINSRC ?= release
# Для BINSRC=local — каталог с готовыми nfqws2/mdig/ip2net
BINDIR ?=
# Класть ли blockcheck2 в пакет (нужен для подбора стратегии на самом роутере)
INCLUDE_BLOCKCHECK ?= 1

BUILD  := build
DIST   := dist
SRCDIR := $(BUILD)/src/$(REF)
# BINSRC (и BINDIR для BINSRC=local) входят в путь: иначе .stamp от прошлой сборки
# заставил бы `make ipk BINSRC=source` молча переупаковать бинарники из релиза
BINKEY := $(BINSRC)$(if $(BINDIR),-$(shell printf %s "$(BINDIR)" | cksum | cut -d" " -f1))
BINOUT := $(BUILD)/bin/$(ARCH)/$(BINKEY)
ROOT   := $(BUILD)/root/$(ARCH)
VERSION := $(patsubst v%,%,$(REF))-$(PKG_REVISION)
IPK    := $(DIST)/zapret2_$(VERSION)_$(ARCH).ipk

export PKG_REVISION
export INCLUDE_BLOCKCHECK

.PHONY: all ipk ipk-all source binaries stage inspect check test check-config archs clean distclean help

all: ipk

help:
	@sed -n '1,12p' Makefile
	@echo ""
	@echo "Переменные: REF=$(REF) ARCH=$(ARCH) BINSRC=$(BINSRC) PKG_REVISION=$(PKG_REVISION)"
	@echo "Архитектуры: $(ARCHS)"

archs:
	@echo $(ARCHS)

# Печать значения любой переменной: make print-BINOUT. Используется тестами.
print-%:
	@echo "$($*)"

source: $(SRCDIR)/.stamp
$(SRCDIR)/.stamp:
	@scripts/fetch-source.sh $(REF) $(SRCDIR)
	@touch $@

binaries: $(BINOUT)/.stamp
$(BINOUT)/.stamp: $(SRCDIR)/.stamp
	@case "$(BINSRC)" in \
	  release) scripts/fetch-binaries.sh $(REF) $(ARCH) $(BINOUT) ;; \
	  source)  scripts/build-binaries.sh $(SRCDIR) $(ARCH) $(BINOUT) ;; \
	  local)   [ -n "$(BINDIR)" ] || { echo "BINSRC=local требует BINDIR=<каталог>" >&2; exit 1; }; \
	           mkdir -p $(BINOUT); \
	           for f in nfqws2 mdig ip2net; do \
	             [ -f "$(BINDIR)/$$f" ] || { echo "нет $(BINDIR)/$$f" >&2; exit 1; }; \
	             cp "$(BINDIR)/$$f" "$(BINOUT)/$$f"; chmod 755 "$(BINOUT)/$$f"; \
	           done ;; \
	  *) echo "BINSRC должен быть release, source или local" >&2; exit 1 ;; \
	esac
	@touch $@

stage: $(ROOT)/.stamp
$(ROOT)/.stamp: $(BINOUT)/.stamp $(shell find package -type f 2>/dev/null)
	@scripts/stage.sh $(SRCDIR) $(BINOUT) $(ARCH) $(ROOT)
	@touch $@

ipk: $(IPK)
$(IPK): $(ROOT)/.stamp
	@scripts/mkipk.sh $(ROOT) $(ARCH) $(REF) $(IPK)

ipk-all:
	@for a in $(ARCHS); do $(MAKE) --no-print-directory ipk ARCH=$$a || exit 1; done
	@ls -l $(DIST)

inspect: $(IPK)
	@scripts/inspect-ipk.sh $(IPK) $(ARCH)

# Полный офлайн-набор тестов (см. tests/README.md)
test:
	@tests/run.sh

# Синтаксическая проверка всего, что уезжает на роутер, плюс сборочных скриптов
check:
	@rc=0; \
	for f in install.sh uninstall.sh scripts/*.sh tests/run.sh tests/t/*.sh \
	         package/control/postinst package/control/prerm package/control/postrm \
	         package/root/opt/etc/init.d/S99zapret2 package/root/opt/etc/ndm/netfilter.d/*.sh \
	         package/root/opt/bin/* package/root/opt/etc/zapret2/config \
	         package/root/opt/etc/zapret2/custom.d/*; do \
	  if sh -n "$$f" 2>/dev/null; then echo "ok   $$f"; else echo "СБОЙ $$f"; rc=1; fi; \
	done; \
	exit $$rc

# Сверка нашего конфига с config.default upstream: ищем переменные, которые
# появились/исчезли наверху и о которых мы ещё не знаем.
check-config: $(SRCDIR)/.stamp
	@vars() { grep -oE '^#?[A-Z][A-Z0-9_]*=' "$$1" | tr -d '#=' | sort -u; }; \
	vars $(SRCDIR)/config.default >$(BUILD)/.vars-upstream; \
	vars package/root/opt/etc/zapret2/config >$(BUILD)/.vars-ours; \
	echo "есть в config.default upstream, но не упомянуто у нас:"; \
	comm -23 $(BUILD)/.vars-upstream $(BUILD)/.vars-ours | sed 's/^/  /'; \
	echo "есть у нас, но не в config.default (наши добавки — проверь, что не опечатка):"; \
	comm -13 $(BUILD)/.vars-upstream $(BUILD)/.vars-ours | sed 's/^/  /'

clean:
	rm -rf $(BUILD)/root $(BUILD)/bin $(DIST)

distclean:
	rm -rf $(BUILD) $(DIST)
