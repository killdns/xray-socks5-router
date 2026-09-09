# Xray SOCKS5 Router

[English](README.md) · [Docker Hub](https://hub.docker.com/r/killdns/xray-socks5-router) · [Docker Hub README](README_DOCKERHUB.md)

Мультиплатформенный Docker-образ с двумя входами в один Xray outbound:

- L3-шлюз для маршрутизируемого IPv4-трафика;
- SOCKS5-сервер HevSocks5Server с TCP `CONNECT` и UDP `ASSOCIATE`.

Платформы: `linux/amd64` (x86_64), `linux/arm64` (AArch64) и
`linux/arm/v7` (32-битный ARMv7, включая совместимые MikroTik).

## Режимы маршрутизации

| Режим | Где использовать | Требования ядра |
|---|---|---|
| `tproxy` | Обычный Linux Docker | рабочий TPROXY в iptables/nftables |
| `tun` | RouterOS containers и Linux | `/dev/net/tun`, `NET_ADMIN`, policy routing |

По умолчанию используется `tproxy`. Режим `tun` не применяет iptables или
nftables для перехвата и подходит для RouterOS, где ядро не предоставляет
контейнерам netfilter target TPROXY.

Это L3-шлюз, не Ethernet-мост. Внешний маршрутизатор направляет выбранные IP-сети
или policy route на IP контейнера. Образ не переносит VLAN, broadcast domain или
Docker network через Xray.

### TUN

```text
маршрутизируемый клиент/сеть
        |
        | правило iif -> таблица 100
        v
xray0 (Xray TUN inbound) -> Xray outbound

SOCKS5-клиент -> HevSocks5Server :1080
        |
        | правило по UID процесса -> таблица 200
        v
xray0 -> Xray outbound
```

Собственные соединения Xray остаются в таблице `main`, поэтому подключение к
серверу не зацикливается в `xray0`.

### TPROXY

```text
SOCKS5-клиент -> HevSocks5Server :1080
        |
        | UID mark 0x2 -> таблица 200
        v
внутренняя петля VRF/veth
        |
        | TPROXY mark 0x1 -> таблица 100
        v
Xray dokodemo-door :12345 -> Xray outbound
```

VRF/veth — внутренняя деталь только режима `tproxy`, а не VLAN или Docker-сеть.
В режиме `tun` эта петля не создаётся.

## Конфигурация подключения

Контейнер читает `/etc/xray/config.json`. Генератор полного конфига из одной
ссылки `vless://` требует Python 3.10+ только на машине, где создаётся файл.

```bash
# TPROXY
python3 tools/vless_to_config.py \
  --uri-file ./vless-link.txt \
  --routing-mode tproxy \
  --output ./config/config.json

# TUN
python3 tools/vless_to_config.py \
  --uri-file ./vless-link.txt \
  --routing-mode tun \
  --tun-interface xray0 \
  --tun-mtu 1400 \
  --output ./config/config.json
```

PowerShell использует те же параметры. Генератор не перезаписывает файл без
`--force`. Не передавайте секретную ссылку через `--uri`, если не хотите оставить
её в истории команд. Ссылку, готовый JSON, UUID, параметры REALITY и SOCKS-пароль
нельзя коммитить.

Для ручной настройки скопируйте
[`examples/config/config.example.json`](examples/config/config.example.json).

Если выбран `ROUTING_MODE=tun`, а смонтированный конфиг содержит TPROXY inbound
`dokodemo-door`, entrypoint автоматически преобразует его во временный TUN-конфиг
под `/run`. Исходный файл остаётся неизменным, а тег inbound сохраняется. Нативный
TUN-конфиг используется как есть; имя его интерфейса должно совпадать с
`TUN_INTERFACE`.

## Запуск

[`examples/compose.yaml`](examples/compose.yaml) показывает запуск TPROXY с
отдельными входной и выходной Docker-сетями. Для TUN добавьте устройство:

```yaml
services:
  gateway:
    image: killdns/xray-socks5-router:0.2.0
    cap_add: [NET_ADMIN, NET_RAW]
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      net.ipv4.ip_forward: "1"
      net.ipv4.conf.all.rp_filter: "0"
      net.ipv4.conf.default.rp_filter: "0"
    environment:
      ROUTING_MODE: tun
      TUN_INTERFACE: xray0
      SOCKS_ALLOW_NO_AUTH: "1"
    volumes:
      - ./config/config.json:/etc/xray/config.json:ro
```

На RouterOS задайте `ROUTING_MODE=tun` в envlist и убедитесь, что контейнер видит
`/dev/net/tun`.

Entrypoint считает интерфейс исходного default route выходным, а другой интерфейс
с глобальным IPv4 — входным. При одном интерфейсе он используется в обе стороны.
Задайте `INBOUND_INTERFACE` и `OUTBOUND_INTERFACE` явно, если определение
неоднозначно. Для удалённых клиентских сетей используйте `RETURN_CIDRS` вместе с
`INBOUND_GATEWAY`.

## Переменные окружения

### Общие

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `XRAY_CONFIG` | `/etc/xray/config.json` | Конфиг Xray |
| `ROUTING_MODE` | `tproxy` | `tproxy` или `tun` |
| `INBOUND_INTERFACE` | автоматически | Интерфейс транзитного трафика |
| `INBOUND_GATEWAY` | пусто | Next hop для `RETURN_CIDRS` |
| `OUTBOUND_INTERFACE` | интерфейс default route | Uplink/underlay |
| `OUTBOUND_GATEWAY` | gateway default route | Обычный шлюз контейнера |
| `RETURN_CIDRS` | пусто | Сети клиентов через входной gateway |
| `LOCAL_BYPASS_CIDRS` | private/reserved IPv4 | Адреса, идущие напрямую |

### TUN

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `TUN_INTERFACE` | `xray0` | Имя TUN-интерфейса |
| `TUN_GATEWAY` | `198.18.0.1/30` | Адрес для автоматического преобразования |
| `TUN_MTU` | `1400` | MTU для автоматического преобразования |
| `TUN_TABLE` | `100` | Policy table L3-трафика |
| `TUN_PRIORITY` | `1000` | Приоритет правила входного интерфейса; на RouterOS больше 200 |
| `TUN_SOCKS_PRIORITY` | `900` | Приоритет правила UID Hev; на RouterOS больше 200 |
| `TUN_WAIT_SECONDS` | `15` | Ожидание создания TUN-интерфейса |

### TPROXY

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `TPROXY_PORT` | `12345` | Порт прозрачного inbound |
| `TPROXY_MARK` | `0x1/0x1` | Метка перехвата |
| `TPROXY_TABLE` | `100` | Policy table TPROXY |
| `TPROXY_PRIORITY` | `100` | Приоритет policy rule |
| `IPTABLES_BIN` | `iptables` | При необходимости `iptables-legacy` |

### SOCKS5

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `ENABLE_SOCKS` | `1` | Запустить HevSocks5Server |
| `SOCKS_BIND` | `0.0.0.0` | Адрес TCP/UDP listener |
| `SOCKS_PORT` | `1080` | TCP-порт SOCKS5 |
| `SOCKS_USER` / `SOCKS_PASSWORD` | пусто | Учётные данные; только вместе |
| `SOCKS_ALLOW_NO_AUTH` | `0` | Обязательно `1` для запуска без логина и пароля |
| `SOCKS_DNS_SERVER` | `1.1.1.1` | DNS resolver контейнера |
| `SOCKS_WORKERS` | `2` | Число workers Hev |
| `SOCKS_LOG_LEVEL` | `warn` | `debug`, `info`, `warn` или `error` |
| `SOCKS_UDP_PORT_MIN` / `MAX` | `20000` / `20999` | Диапазон UDP relay |
| `SOCKS_UDP_ADVERTISE_IP` | пусто | Доступный клиенту IPv4 для UDP `ASSOCIATE` |

## Сборка, безопасность и ограничения

```bash
docker build -t xray-socks5-router:test .
./tests/smoke.sh
docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7 \
  -t killdns/xray-socks5-router:0.2.0 .
```

Smoke test проверяет L3 TCP/UDP и SOCKS5 TCP/UDP в обоих режимах.

- Монтируйте конфиг Xray только для чтения.
- Не публикуйте SOCKS без авторизации в недоверенную сеть.
- Открывайте TCP-порт SOCKS и весь диапазон UDP relay только при необходимости.
- TUN-трафик fail-closed: при остановке Xray выбранные маршруты перестают ходить.
- ICMP echo от Xray TUN означает приём пакета TUN-стеком, а не доказанный ответ
  удалённого узла.
- В этой версии настраивается IPv4-транзит; IPv6-транзит вне scope.

[Документация Xray TUN](https://github.com/XTLS/Xray-core/blob/v26.7.28/proxy/tun/README.md)
