# Xray SOCKS5 Router

[GitHub source and full documentation](https://github.com/killdns/xray-socks5-router) ·
[Russian documentation](https://github.com/killdns/xray-socks5-router/blob/main/README_RU.md)

A multi-platform Docker image that provides an L3 gateway for routed IPv4
traffic through Xray and a HevSocks5Server frontend with TCP `CONNECT` and UDP
`ASSOCIATE`.

Platforms: `linux/amd64` (x86_64), `linux/arm64` (AArch64), and `linux/arm/v7`
(32-bit ARMv7, including compatible MikroTik devices).

## Routing modes

| Mode | Typical host | Requirement |
|---|---|---|
| `tproxy` | Standard Linux Docker | working iptables/nftables TPROXY |
| `tun` | RouterOS containers or Linux | `/dev/net/tun`, `NET_ADMIN`, policy routing |

`tproxy` is the default. `tun` avoids netfilter interception and is intended for
RouterOS kernels that do not expose the TPROXY target to containers.

This is an L3 next hop, not an L2 bridge. Route selected networks or a policy
table to the container IP. It does not bridge VLANs, Ethernet frames, broadcast
domains, or Docker networks.

```text
routed client/network
        |
        | iif policy rule -> table 100
        v
xray0 (Xray TUN inbound) -> Xray outbound

container-local process except Xray
        |
        | inverted Xray-UID rule -> table 100
        v
xray0 -> Xray outbound

SOCKS5 client -> HevSocks5Server :1080
        |
        | process-UID policy rule -> table 200
        v
xray0 -> Xray outbound
```

Xray runs under a dedicated UID with only ambient `CAP_NET_ADMIN`. All other
container-local traffic enters TUN, while Xray's own upstream sockets keep using
the main table to avoid a loop.

In `tproxy` mode, SOCKS traffic instead re-enters Xray through an internal
VRF/veth loop and the TPROXY inbound. That loop is not a VLAN or Docker network,
and TUN mode does not create it.

## Quick start

```bash
docker pull killdns/xray-socks5-router:0.2.1
```

TUN example:

```yaml
services:
  gateway:
    image: killdns/xray-socks5-router:0.2.1
    cap_add: [NET_ADMIN, NET_RAW]
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      net.ipv4.ip_forward: "1"
      net.ipv4.conf.all.rp_filter: "0"
      net.ipv4.conf.default.rp_filter: "0"
    environment:
      ROUTING_MODE: tun
      SOCKS_ALLOW_NO_AUTH: "1"
    volumes:
      - ./config/config.json:/etc/xray/config.json:ro
```

On RouterOS, set `ROUTING_MODE=tun` in the envlist and confirm that the
container sees `/dev/net/tun`.

## Generate `config.json`

The GitHub repository includes a Python 3.10+ generator for one `vless://` URI:

```bash
python3 tools/vless_to_config.py \
  --uri-file ./vless-link.txt \
  --routing-mode tun \
  --tun-interface xray0 \
  --tun-mtu 1400 \
  --output ./config/config.json
```

Use `--routing-mode tproxy` for TPROXY. With `ROUTING_MODE=tun`, the entrypoint
can also convert an existing TPROXY `dokodemo-door` inbound to an ephemeral TUN
config under `/run`; the mounted file remains unchanged.

Never commit the URI or generated configuration.

## Environment reference

| Variable | Default | Purpose |
|---|---|---|
| `XRAY_CONFIG` | `/etc/xray/config.json` | Mounted Xray configuration |
| `ROUTING_MODE` | `tproxy` | `tproxy` or `tun` |
| `INBOUND_INTERFACE` | auto | Interface receiving routed traffic |
| `INBOUND_GATEWAY` | empty | Next hop for `RETURN_CIDRS` |
| `OUTBOUND_INTERFACE` | default route | Underlay/uplink interface |
| `OUTBOUND_GATEWAY` | default gateway | Underlay gateway |
| `RETURN_CIDRS` | empty | Client networks returned through the inbound gateway |
| `LOCAL_BYPASS_CIDRS` | private/reserved IPv4 | Destinations routed directly |
| `TUN_INTERFACE` | `xray0` | Xray TUN interface name |
| `TUN_GATEWAY` | `198.18.0.1/30` | Address used during automatic conversion |
| `TUN_MTU` | `1400` | MTU used during automatic conversion |
| `TUN_TABLE` | `100` | Policy table for routed traffic |
| `TUN_PRIORITY` | `1000` | Inbound-interface rule priority; above 200 on RouterOS |
| `TUN_SOCKS_PRIORITY` | `900` | Hev UID rule priority; above 200 on RouterOS |
| `TUN_LOCAL_PRIORITY` | `950` | Route container-local traffic except Xray through TUN |
| `TPROXY_PORT` | `12345` | TPROXY inbound port |
| `TPROXY_MARK` | `0x1/0x1` | TPROXY packet mark |
| `ENABLE_SOCKS` | `1` | Start HevSocks5Server |
| `SOCKS_BIND` | `0.0.0.0` | TCP and UDP listen address |
| `SOCKS_PORT` | `1080` | SOCKS5 TCP port |
| `SOCKS_USER` / `SOCKS_PASSWORD` | empty | Credentials; set both together |
| `SOCKS_ALLOW_NO_AUTH` | `0` | Must be `1` to run without credentials |
| `SOCKS_DNS_SERVER` | `1.1.1.1` | Container resolver |
| `SOCKS_LOG_LEVEL` | `warn` | `debug`, `info`, `warn`, or `error` |
| `SOCKS_UDP_PORT_MIN` / `MAX` | `20000` / `20999` | UDP relay range |
| `SOCKS_UDP_ADVERTISE_IP` | empty | Client-reachable UDP relay IPv4 |

Without credentials, startup fails unless `SOCKS_ALLOW_NO_AUTH=1` is explicitly
set. Never expose unauthenticated SOCKS to an untrusted network.

The image requires `NET_ADMIN` and `NET_RAW`, not privileged mode. Mount the Xray
config read-only. TUN is fail-closed for traffic selected by its policy table.
This release configures IPv4 transit routing; IPv6 transit is out of scope.

See the [GitHub README](https://github.com/killdns/xray-socks5-router) for full
examples, tests, source code, and upstream links.
