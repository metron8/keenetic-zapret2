# zapret2 для Keenetic — Entware-пакет (.ipk)

Прототип opkg-пакета, который ставит [zapret2](https://github.com/bol-van/zapret2)
на роутер Keenetic поверх Entware. Своего кода обхода DPI здесь нет: пакет берёт
upstream как есть и добавляет то, без чего zapret на Keenetic не живёт —
init-скрипт под Entware, хук `ndm`, фикс UDP-маскарада и конфиг с правильными для
Keenetic значениями.

## Почему Keenetic нельзя просто «поставить zapret по мануалу»

В мануале upstream (`docs/manual.md`) про Keenetic сказано: работает под entware,
но «в составе дополнительных обеспечительных мер, которые выходят за рамки проекта».
Меры такие:

| Проблема Keenetic | Что делает пакет |
|---|---|
| `ndm` регулярно пересобирает netfilter и вычищает чужие правила — zapret «слетает» каждые несколько минут | хук `/opt/etc/ndm/netfilter.d/50-zapret2.sh` просит init-скрипт переставить правила; вызовы коалесцируются, потому что ndm дёргает хук пачкой |
| Keenetic использует собственную метку `ndmmark` и не маскарадит UDP-пакеты, сгенерированные nfqws — они уходят в WAN с LAN-адресом и режутся провайдером | `custom.d/10-keenetic-udp-fix` (скрипт из upstream) добавляет `MASQUERADE` для пакетов с `DESYNC_MARK` |
| entware держит пользователей в `/opt/etc/passwd`, а статические бинарники zapret ищут их в `/etc/passwd` на r/o разделе прошивки — `--user` не срабатывает | в конфиге зафиксирован `WS_USER=nobody`, который заведомо есть в прошивке |
| обновление пакета затрёт `/opt/zapret2` вместе с настройками и списками | конфиг, списки и `custom.d` вынесены в `/opt/etc/zapret2` (`ZAPRET_RW`) и объявлены conffiles |
| аппаратное ускорение NAT уводит трафик мимо netfilter | не трогаем автоматически (это настройка роутера), но `zapret2 check` про это предупреждает |

## Что попадает на роутер

```
/opt/zapret2/                       # runtime-часть upstream (opkg-owned, перезаписывается при обновлении)
├── common/ ipset/ lua/ files/      #   библиотеки шелла, lua-стратегии, бинарные payload'ы
├── init.d/sysv/functions           #   функции запуска демонов и правил
├── nfq2/nfqws2  mdig/mdig  ip2net/ip2net
├── blockcheck2.sh, blockcheck2.d/  #   подбор стратегии прямо на роутере
└── config.default                  #   справочный конфиг upstream

/opt/etc/zapret2/                   # r/w часть (conffiles, переживает обновление)
├── config                          #   рабочий конфиг
├── custom.d/10-keenetic-udp-fix
└── ipset/zapret-hosts-user*.txt    #   пользовательские списки

/opt/etc/init.d/S99zapret2          # автозапуск через rc.unslung при монтировании /opt
/opt/etc/ndm/netfilter.d/50-zapret2.sh
/opt/bin/zapret2                    # обёртка: zapret2 start|status|check|...
/opt/bin/zapret2-list               # обёртка над ipset/get_*.sh с правильным ZAPRET_RW
```

## Требования к роутеру

1. **Entware** на USB-накопителе (`/opt` смонтирован). Ставится штатно из веб-интерфейса
   Keenetic или по инструкции Entware.
2. Компонент прошивки **«Модули ядра подсистемы Netfilter»** — без него нет
   `NFQUEUE` и `/proc/net/netfilter/nfnetlink_queue`. Включается в веб-интерфейсе:
   Общие настройки → Обновления и компоненты → Изменить набор компонентов.
3. Компонент **IPset**, если планируешь `MODE_FILTER=ipset`.
4. Проверить, не мешает ли **аппаратное ускорение**: если правила стоят, а обход не
   работает, выключи его и проверь снова.

Всё это проверяет команда `zapret2 check` уже на роутере.

## Сборка пакета

Сборка идёт на обычной linux-машине, не на роутере.

```bash
# готовые статические бинарники из релиза upstream (быстро, по умолчанию)
make ipk ARCH=mipsel-3.4
make ipk ARCH=aarch64-3.10

# всё сразу
make ipk-all

# кросс-сборка из исходников (musl-cross + luajit2 + libnetfilter_queue)
make ipk ARCH=mipsel-3.4 BINSRC=source
```

Результат — `dist/zapret2_<версия>-<ревизия>_<арх>.ipk`.

Полезные цели:

| Цель | Что делает |
|---|---|
| `make help` | шпаргалка по переменным |
| `make check` | синтаксическая проверка всех шелл-скриптов пакета |
| `make test` | полный офлайн-набор тестов (сеть и роутер не нужны) |
| `make inspect ARCH=...` | распаковать собранный .ipk и проверить структуру, control, права и **архитектуру ELF** |
| `make check-config` | сверить наш `config` с `config.default` upstream — ловит расхождения после обновления zapret2 |
| `make clean` / `make distclean` | убрать артефакты |

Переменные: `REF` (тег zapret2, по умолчанию `v1.0.5.1`), `ARCH`, `BINSRC`
(`release` \| `source` \| `local`), `BINDIR` (для `BINSRC=local`), `PKG_REVISION`,
`INCLUDE_BLOCKCHECK`.

### Какую архитектуру брать

| Entware ARCH | Модели Keenetic | Каталог в релизе upstream |
|---|---|---|
| `mipsel-3.4` | MT7621: Giga KN-1010/1011, Ultra KN-1810, Viva и т.п. | `binaries/linux-mipsel` |
| `aarch64-3.10` | MT798x: Giga KN-1012, Hopper, Peak и т.п. | `binaries/linux-arm64` |

Точное значение видно на самом роутере: `opkg print-architecture`.

### Требования сборочной машины

Для `BINSRC=release`: `curl`/`wget`, `tar`, `sha256sum`, `git`.
Для `BINSRC=source` дополнительно: `gcc` (плюс `gcc-multilib` — хостовый `buildvm`
luajit для 32-битных целей собирается как 32-битный), `make`, `patch`, `xz`, `bzip2`,
`pkg-config`, заголовки `sys/queue.h` и `sys/capability.h` (пакет `libcap-dev`;
если их нет, скрипт скачает их из upstream-исходников).

## Установка на роутер

### Одной командой (рекомендуется)

`install.sh` сам определяет архитектуру, качает нужный `.ipk` из релиза, сверяет
sha256, ставит, прописывает `IFACE_WAN`, **скачивает список доменов и включает
`MODE_FILTER=hostlist`**, и запускает сервис — но только если `zapret2 check`
прошёл без ошибок. Если что-то не так, он не трогает firewall и печатает, что
чинить.

Список берётся скриптом `get_reestr_resolvable_domains.sh`. Он выбран не
случайно: этот скрипт скачивает доменный список **первым делом**, а ipset трогает
только в конце. У `get_refilter_domains.sh` и `get_antizapret_domains.sh` порядок
обратный — они выходят до загрузки, если не отработала ipset-часть, а компонент
IPset на Keenetic не обязателен.

Если список скачать не удалось, режим **остаётся `none`**. Это не перестраховка:
`hostlist` с пустым списком означает, что nfqws не обрабатывает ничего и обход
молча не работает вовсе. Лучше обрабатывать весь трафик, чем ничего.

```bash
ssh root@192.168.1.1
curl -fL -o /opt/tmp/install.sh https://raw.githubusercontent.com/metron8/keenetic-zapret2/main/install.sh
sh /opt/tmp/install.sh
```

| Ключ | Зачем |
|---|---|
| `--arch=ARCH` | не определять архитектуру, взять эту |
| `--iface=IFACE` | не определять WAN, вписать этот интерфейс |
| `--tag=TAG` | ставить из конкретного релиза |
| `--ipk=PATH` | взять готовый `.ipk` с диска, ничего не качать |
| `--no-lists` | не качать список, оставить `MODE_FILTER=none` |
| `--lists=SCRIPT` | качать другим скриптом (`zapret2-list --list` покажет варианты) |
| `--autohostlist` | режим `autohostlist`: список плюс самопополнение по блокировкам |
| `--no-start` | только поставить и настроить, firewall не трогать |
| `--force-start` | запустить, даже если `check` нашёл проблемы |
| `--force` | переустановить ту же версию |

Стратегию обхода (`NFQWS2_OPT`) скрипт не подбирает: это делает `blockcheck2` на
самом роутере и это долго.

### Вручную

```bash
scp dist/zapret2_1.0.5.1-1_mipsel-3.4.ipk root@192.168.1.1:/opt/tmp/
ssh root@192.168.1.1
opkg install /opt/tmp/zapret2_1.0.5.1-1_mipsel-3.4.ipk
```

`postinst` сразу прогоняет `zapret2 check`, наполняет список доменов
(`zapret2-list --bootstrap`) и печатает, чего не хватает. То есть список
приезжает при любом способе установки, не только через `install.sh`.

Отключается переменной окружения:

```bash
ZAPRET_NO_LISTS=1 opkg install /opt/tmp/zapret2_1.0.5.1-1_mipsel-3.4.ipk
```

На обновлении список не перекачивается: конфиг и `ipset/` — r/w часть, они
на месте. Неудачная загрузка не валит установку пакета.

Сервис **не стартует автоматически при первой установке** — сначала конфиг.

## Настройка

1. **WAN-интерфейс.** В `/opt/etc/zapret2/config` раскомментируй `IFACE_WAN` и
   впиши свой: `ppp0` для PPPoE, обычно `eth3` для IPoE. Автоопределение по default
   route работает, но «уезжает» при переключении на резервный канал, а от этого
   зависит корректность UDP-фикса.

2. **Стратегия обхода.** Значение `NFQWS2_OPT` в конфиге — стартовый набор из
   upstream, он подходит не всем провайдерам. Подбирается на самом роутере:

   ```bash
   ZAPRET_BASE=/opt/zapret2 ZAPRET_RW=/opt/etc/zapret2 sh /opt/zapret2/blockcheck2.sh
   ```

   Что blockcheck выдаст рабочим — то и вписывай в `NFQWS2_OPT`.

3. **Запуск.**

   ```bash
   zapret2 start
   zapret2 status     # демоны, метка запуска и число правил NFQUEUE в mangle
   zapret2 check      # предпосылки: модули ядра, iptables, WS_USER, хуки, интерфейсы
   ```

Дальше автозапуск при монтировании `/opt` уже включён (`S99zapret2` подхватывается
`rc.unslung` из хука Entware `/opt/etc/ndm/fs.d/100-entware.sh`).

### Команды

```
zapret2 start | stop | restart | status | check
zapret2 start-fw | stop-fw | restart-fw            # только правила
zapret2 start-daemons | stop-daemons | restart-daemons
zapret2 reload-ifsets | list-ifsets | list-table
zapret2 reapply                                    # служебная, её зовёт хук ndm
zapret2-list --list                                # доступные ipset/get_*.sh
zapret2-list get_user.sh                           # обновить списки в /opt/etc/zapret2/ipset
```

## Списки: к каким ресурсам применяются правила

> Это делается автоматически при установке — и через `install.sh`, и через
> обычный `opkg install` (за счёт `postinst`). Раздел ниже нужен, если загрузка
> не удалась, если хочешь поменять режим или источник списка.

В самом пакете в конфиге стоит **`MODE_FILTER=none`**, и это означает, что списка
нет вообще: маркеры `<HOSTLIST>` и `<HOSTLIST_NOAUTO>` в `NFQWS2_OPT`
разворачиваются в пустую строку, а стратегия применяется **ко всему** трафику на
портах из `NFQWS2_PORTS_TCP` / `NFQWS2_PORTS_UDP` (80, 443, UDP 443). Для первого
запуска так проще — ничего не зависит от актуальности списков, — но на слабом
роутере это заметно дороже по CPU.

Чтобы правила применялись выборочно, переключи `MODE_FILTER`:

| Значение | Что делает |
|---|---|
| `none` | без фильтрации, стратегия ко всему трафику на указанных портах |
| `hostlist` | только домены из файлов ниже |
| `autohostlist` | то же плюс zapret сам дописывает домены, на которых увидел блокировку |
| `ipset` | фильтрация по IP-адресам (нужен компонент IPset) |

### Где лежат файлы

Все списки — в `HOSTLIST_BASE=/opt/etc/zapret2/ipset`, то есть в r/w части,
которую обновление пакета не затирает.

| Файл | Что это | conffile |
|---|---|---|
| `zapret-hosts-user.txt` | твой ручной список: по домену в строке, поддомены попадают автоматически | да |
| `zapret-hosts-user-exclude.txt` | исключения — эти домены не трогать, даже если попали в общий список | да |
| `zapret-hosts.txt` / `.txt.gz` | большой список, скачанный `get_*.sh` | нет |
| `zapret-hosts-auto.txt` | автосписок, его ведёт сам zapret при `MODE_FILTER=autohostlist` | нет |

Два пользовательских файла объявлены conffiles — `opkg upgrade` их сохранит.

### Править руками

```bash
vi /opt/etc/zapret2/ipset/zapret-hosts-user.txt   # по домену в строке
zapret2 restart
```

### Пополнять автоматически

Обёртка `zapret2-list` гоняет upstream-скрипты `ipset/get_*.sh` с правильным
`ZAPRET_RW`. Запускать их напрямую нельзя: они посчитают `ZAPRET_RW` равным
`ZAPRET_BASE` и запишут списки в `/opt/zapret2/ipset`, который затрёт обновление
пакета.

```bash
zapret2-list --list                              # какие скрипты есть
zapret2-list get_user.sh                         # обработать свой список
zapret2-list get_antifilter_allyouneed.sh        # скачать готовый список
zapret2 restart
```

В комплекте upstream есть наборы от antifilter, antizapret, refilter и реестра.
Переменная `GETLIST` в конфиге задаёт скрипт по умолчанию — тогда достаточно
`zapret2-list` без аргументов.

Если не хочется вести список вручную, самый необременительный режим —
`autohostlist`: домены добавляются сами, когда zapret видит признаки блокировки
(ретрансмиты, RST). Пороги настраиваются переменными `AUTOHOSTLIST_*`, они уже
есть в конфиге.

## Удаление

```bash
opkg remove zapret2
```

`prerm` снимает правила и глушит демоны до удаления файлов. Conffiles (`config`,
списки, `custom.d`) opkg сохраняет — удали `/opt/etc/zapret2` вручную, если они
больше не нужны.

## Тесты

```bash
make test          # весь набор
tests/run.sh 050   # только файлы, чьё имя содержит 050
```

Тесты полностью офлайн: дерево upstream и «бинарники» под mips/aarch64 генерятся
фикстурами (`tests/lib.sh`), а upstream `init.d/sysv/functions` подменяется стабом,
который пишет вызовы в лог вместо того, чтобы трогать настоящий netfilter.

| Файл | Что покрывает |
|---|---|
| `t/010-shell-syntax.sh` | всё парсится `/bin/sh`; файлы, которые ставятся исполняемыми, исполняемы и в git |
| `t/020-shellcheck.sh` | shellcheck (пропускается, если его нет локально; в CI есть всегда) |
| `t/030-package-build.sh` | сборка `.ipk` под обе арки, состав пакета, conffiles, отсутствие исходников; инспектор обязан **забраковать** пакет с бинарниками чужой арки |
| `t/040-init-lifecycle.sh` | start/stop/status, порядок снятия правил, `INIT_APPLY_FW=0`, подкоманды, поведение без конфига |
| `t/050-reapply.sh` | коалесцирование заявок от ndm, хук `netfilter.d`, и две регрессии: `stop` внутри окна задержки отменяет переустановку; осиротевшая метка не отключает хук навсегда |
| `t/060-lock.sh` | снятие блокировки от мёртвого процесса, уважение живой, конечный таймаут; регрессия на pid воркера в блокировке |
| `t/070-maintainer-scripts.sh` | сценарии обновления и удаления, метка автозапуска, поиск метки запуска вне `/var/run`, `IPKG_INSTROOT` |
| `t/080-makefile.sh` | сквозная офлайн-сборка через `make`, регрессия на переиспользование бинарников при смене `BINSRC`/`BINDIR` |
| `t/090-config-consistency.sh` | Keenetic-критичные значения конфига, согласованность путей между init, хуком и `custom.d`, полнота шаблона `control` |

Регрессионные тесты проверены мутациями: если вернуть исходный дефект, падает
ровно тот случай, который его описывает.

Для тестируемости в скриптах есть три переменные окружения, в бою пустые:
`ZAPRET_RUNDIR` (где лежат метки и pid-файлы), `ZAPRET_ROOT_PREFIX` (префикс
корня для maintainer-скриптов) и `ZAPRET_LOCK_WAIT` (таймаут блокировки).

## CI/CD

`.github/workflows/ci.yml` — на каждый push и PR:

* `test` — `make check` + весь набор тестов, плюс shellcheck;
* `build` — матрица `mipsel-3.4` / `aarch64-3.10`: собирает `.ipk` из релизных
  бинарников upstream, прогоняет `make inspect` и заливает пакет в артефакты;
* `config-drift` — информационно показывает расхождение нашего конфига с
  `config.default` upstream (не роняет сборку).

`.github/workflows/release.yml` — на тег `v*`: собирает обе арки, проверяет,
считает sha256 и выкладывает `.ipk` в GitHub Release.

Тег репозитория имеет вид `v<версия zapret2>-<ревизия пакета>`:

```bash
git tag v1.0.5.1-1 && git push --tags   # соберёт пакет из zapret2 v1.0.5.1, ревизия 1
```

Собрать релиз из произвольной версии upstream без тега можно через
`workflow_dispatch` (кнопка Run workflow, параметры `upstream_ref` и `pkg_revision`).

## Что именно проверено, а что нет

Проверено на сборочной машине и в CI: сборка дерева, формат `.ipk`
(`ipkg`-совместимый gzip-tar с `debian-binary` + `control.tar.gz` + `data.tar.gz`),
поля `control`, права, conffiles, отсутствие исходников в пакете, синтаксис всех
шелл-скриптов, сверка ELF-заголовка бинарников с заявленной архитектурой,
жизненный цикл init-скрипта, коалесцирование хука ndm, блокировки и сценарии
opkg (установка / обновление / удаление).

Не проверено: **установка и работа на живом Keenetic** — под рукой нет железа.
Ветка `BINSRC=source` (кросс-сборка) написана по шагам CI upstream, но целиком
не прогонялась; штатный путь — `BINSRC=release`.

## Как обновлять под новую версию zapret2

```bash
make check-config REF=v1.0.6     # посмотреть, что изменилось в config.default
make ipk-all REF=v1.0.6
```

`check-config` покажет переменные, появившиеся или исчезнувшие в upstream, — это
основной источник расхождений при обновлении.

## Лицензия и авторство

Код zapret2 — авторства [bol-van](https://github.com/bol-van/zapret2), лицензия MIT.
Обвязка в этом репозитории — тоже MIT, см. `LICENSE`.

Собранный `.ipk` содержит код upstream, поэтому в него кладутся оба уведомления:
`/opt/zapret2/LICENSE.upstream.txt` и `/opt/zapret2/LICENSE.packaging.txt`.
