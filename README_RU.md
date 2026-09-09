# Xray SOCKS5 Router

[English](README.md) ·
[Docker Hub](https://hub.docker.com/r/killdns/xray-socks5-router)

Multi-arch Docker-образ L3-шлюза для маршрутизируемого TCP, UDP и DNS-трафика
через Xray со встроенным SOCKS5-сервером
[HevSocks5Server](https://github.com/heiher/hev-socks5-server).

Поддерживаемые платформы:

- `linux/amd64` — x86_64;
- `linux/arm64` — ARM64/AArch64;
- `linux/arm/v7` — 32-битный ARMv7.

## Что здесь является L3

В режиме шлюза контейнер принимает IP-пакеты на входном интерфейсе и
маршрутизирует TCP/UDP-потоки через Xray. На вышестоящем маршрутизаторе IP
контейнера задаётся как next hop для нужных клиентских сетей или таблиц policy
routing — по той же модели, что и у `ssh-tun-gateway`.

Это не L2-мост: контейнер не переносит Ethernet-кадры и не объединяет broadcast-
домены Docker-сетей. TPROXY Xray обрабатывает TCP и UDP, поэтому ICMP и прочие IP
протоколы через прокси не проходят; `ping` не является проверкой этого шлюза.
DNS проходит как TCP/UDP-трафик.

SOCKS5 — дополнительный прикладной вход. Соединения, созданные
HevSocks5Server, принудительно возвращаются в тот же L3-путь через Xray и не
выходят напрямую через underlay.

## Зачем отдельный образ

Официальный образ Xray содержит сам Xray, но не сетевую обвязку транзитного шлюза. Этот проект добавляет:

- прозрачный TPROXY для TCP и UDP;
- исключение сервисов на собственных адресах контейнера из TPROXY;
- policy routing и NAT;
- HevSocks5Server с `CONNECT` и `UDP ASSOCIATE`;
- безопасное направление исходящего трафика Hev обратно в TPROXY Xray;
- healthcheck и корректное завершение обоих процессов;
- multi-arch сборку для трёх платформ.

## Как проходит SOCKS-трафик

```text
SOCKS-клиент
    |
    v
HevSocks5Server :1080
    |
    | UID mark 0x2 + policy table 200
    v
VRF socksvrf -> veth hevout <-> hevin
    |
    | TPROXY mark 0x1 + policy table 100
    v
Xray dokodemo-door :12345
    |
    v
VLESS/REALITY или другой outbound из config.json
```

VRF с внутренней veth-петлёй заставляет ядро действительно вернуть пакеты на
вход сетевого стека. Без этого Linux сократил бы локальный маршрут, а Hev открыл
бы соединение через обычный default route контейнера и обошёл бы Xray. Правило
по UID охватывает TCP, UDP и DNS-запросы процесса Hev. Параметры
`accept_local` и `*_l3mdev_accept` из Compose обязательны для приёма этой
внутренней петли ядром.

## Версии компонентов

- Xray Core `26.7.28`, официальный multi-arch manifest закреплён digest.
- HevSocks5Server `2.13.1`, собирается статически из release tarball с обязательной SHA-256 проверкой.
- Alpine `3.24`, multi-arch manifest закреплён digest.

Обновление версии компонента делается отдельным изменением Dockerfile вместе с digest/checksum и проверкой всех архитектур.

## Быстрый запуск

1. Создайте две обычные пользовательские Docker bridge-сети или используйте
   существующие сети для входа и underlay.
2. В каталоге `examples` скопируйте `.env.example` в `.env`.
3. Создайте `config/config.json` из VLESS-ссылки генератором или вручную по
   инструкции ниже.
4. Запустите Compose. Файл конфигурации подключается внутрь контейнера как
   `/etc/xray/config.json` только для чтения.

Контейнеры во входной Docker-сети обращаются напрямую к IP шлюза. Для доступа к
SOCKS5 извне Docker-хоста опубликуйте или перенаправьте TCP-порт SOCKS и диапазон
UDP relay.

Underlay-сеть должна предоставлять default route контейнера; в Compose для неё
задан `gw_priority`. Имена интерфейсов определяются автоматически: интерфейс
default route считается underlay, второй IPv4-интерфейс — входным. Явно задавать
`INBOUND_INTERFACE` или `OUTBOUND_INTERFACE` нужно только при неоднозначной схеме.

## Конфигурация подключения Xray

Сам Xray принимает JSON-конфигурацию, а не ссылку `vless://...`. В репозитории
есть хостовый генератор: он преобразует одну ссылку в готовый
`config.json`, включая TPROXY inbound и правило маршрутизации. В рабочий
Docker-образ генератор не входит. Из зависимостей ему нужен только Python 3.10+
со стандартной библиотекой.

Сохраните VLESS-ссылку единственной непустой строкой в файле
`vless-link.txt`, затем из корня репозитория выполните:

```powershell
python .\tools\vless_to_config.py `
  --uri-file .\vless-link.txt `
  --output .\examples\config\config.json
```

В Linux команда отличается только путями и именем интерпретатора:

```sh
python3 tools/vless_to_config.py \
  --uri-file ./vless-link.txt \
  --output examples/config/config.json
```

Можно передать ссылку через stdin с `--stdin`. Вариант `--uri` оставлен для
быстрой проверки, но при нём ссылка целиком может попасть в историю shell.
Существующий файл перезаписывается только с `--force`. Генератор не печатает
ссылку или учётные данные; не используйте `--output -`, если не хотите вывести
конфигурацию с секретами в консоль.

Поддерживаются VLESS через RAW (`type=tcp`), WebSocket, gRPC `gun`/`multi`,
HTTPUpgrade, XHTTP и mKCP, а также транспортная защита `none`, TLS и совместимые
сочетания REALITY. Поддерживается актуальный JSON-параметр finalmask `fm`, а
удалённые из Xray mKCP-параметры `seed` и непустой `headerType` отвергаются.
Дублирующиеся, неизвестные и несовместимые параметры тоже не игнорируются —
тихо сгенерировать «почти такой же» конфиг было бы особенно остроумным способом
потратить вечер. Устаревший `type=http` и gRPC `mode=guna` настраиваются вручную.

Преобразование соответствует актуальному
[стандарту VLESS-ссылок Xray](https://github.com/XTLS/Xray-core/discussions/716)
и [формату transport configuration](https://github.com/XTLS/Xray-docs-next/blob/main/docs/en/config/transport.md).

Основные актуальные преобразования:

| Часть VLESS-ссылки | Поле в сгенерированном `config.json` |
|---|---|
| `vless://UUID@...` | `settings.vnext[0].users[0].id` |
| имя или IP после `@` | `settings.vnext[0].address` |
| порт после имени сервера | `settings.vnext[0].port` |
| `flow` | `settings.vnext[0].users[0].flow` |
| `type` | `streamSettings.method` |
| `security` | `streamSettings.security` |
| `sni` | TLS/REALITY `serverName` |
| `fp` | TLS/REALITY `fingerprint` |
| `pbk` | `realitySettings.password` |
| `sid` | `realitySettings.shortId` |
| `pqv` | `realitySettings.mldsa65Verify` |
| `spx` | `realitySettings.spiderX` |

Для ручной настройки скопируйте
[`examples/config/config.example.json`](examples/config/config.example.json) в
`examples/config/config.json` и замените заглушки. TPROXY inbound на порту
`12345` нужно сохранить, если только `TPROXY_PORT` не изменён на то же значение.
Рабочий JSON и типовые имена файлов со ссылками исключены из Git, поскольку в
них находятся UUID и параметры подключения.

Путь к файлу на хосте задаётся в `.env`:

```dotenv
XRAY_CONFIG_FILE=./config/config.json
```

Перед запуском конфигурацию можно проверить тем же образом, каким её проверяет
контейнер:

```sh
docker run --rm \
  --mount type=bind,src="$PWD/config/config.json",dst=/etc/xray/config.json,readonly \
  --entrypoint xray \
  killdns/xray-socks5-router:0.1.0 \
  run -test -config /etc/xray/config.json
```

Если проверка успешна, команда завершается с кодом `0`. При обычном старте
контейнер также сначала выполняет эту проверку и не применяет сетевые правила с
битым JSON.

## Основные переменные

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `XRAY_CONFIG` | `/etc/xray/config.json` | Путь к конфигурации внутри контейнера |
| `INBOUND_INTERFACE` | определяется автоматически | Не-default IPv4-интерфейс транзитного трафика |
| `INBOUND_GATEWAY` | пусто | Нужен только при заданном `RETURN_CIDRS` |
| `OUTBOUND_INTERFACE` | определяется автоматически | Underlay-интерфейс Xray |
| `OUTBOUND_GATEWAY` | определяется автоматически | Обычный default gateway контейнера |
| `RETURN_CIDRS` | пусто | Сети, возвращаемые через входной интерфейс |
| `TPROXY_PORT` | `12345` | Порт TPROXY inbound в Xray config |
| `ENABLE_SOCKS` | `1` | Запуск HevSocks5Server |
| `SOCKS_BIND` | `0.0.0.0` | Адрес прослушивания SOCKS |
| `SOCKS_PORT` | `1080` | TCP-порт SOCKS5 |
| `SOCKS_UDP_PORT_MIN/MAX` | `20000` / `20999` | Диапазон UDP relay |
| `SOCKS_UDP_ADVERTISE_IP` | пусто | Адрес, сообщаемый клиенту для UDP ASSOCIATE |
| `SOCKS_DNS_SERVER` | `1.1.1.1` | DNS внутри контейнера |
| `SOCKS_USER/PASSWORD` | пусто | Необязательная аутентификация |
| `SOCKS_ALLOW_NO_AUTH` | `0` | Явное разрешение работы без пароля |
| `SOCKS_VRF` | `socksvrf` | Внутренняя VRF для возврата SOCKS-трафика в TPROXY |
| `IPTABLES_BIN` | `iptables` | Можно заменить на `iptables-legacy` |

Если логин и пароль не заданы, контейнер намеренно не стартует без
`SOCKS_ALLOW_NO_AUTH=1`.

## Сборка

Нативный образ:

```sh
docker build -t xray-socks5-router:dev .
```

Все архитектуры без публикации:

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7 \
  --pull \
  .
```

Локальный интеграционный тест TCP и UDP:

```sh
./tests/smoke.sh
```

## Безопасность

- Контейнеру нужны `NET_ADMIN` и `NET_RAW`, но не `privileged`.
- Xray config подключается read-only и не должен попадать в Git.
- SOCKS без аутентификации нельзя публиковать в WAN.
- В Dockerfile закреплены upstream manifest digest и SHA-256 исходников Hev.

## Upstream

- [Xray Core](https://github.com/XTLS/Xray-core)
- [HevSocks5Server](https://github.com/heiher/hev-socks5-server)
