# Xray SOCKS5 Router

Multi-platform Docker image that turns Xray into an L3 gateway for routed TCP,
UDP, and DNS traffic. It also runs
[HevSocks5Server](https://github.com/heiher/hev-socks5-server) as an optional
SOCKS5 frontend with TCP `CONNECT` and UDP `ASSOCIATE` support.

[Source code, documentation, and issue tracker on GitHub](https://github.com/killdns/xray-socks5-router).

```text
routed clients / networks -> TPROXY ----> Xray ----> proxy server
                                  ^
                                  |
SOCKS5 clients ----> HevSocks5Server
```

The Hev process cannot silently bypass Xray: its outbound TCP, UDP, and DNS
traffic is returned to the TPROXY path through an internal VRF/veth loop.
Traffic addressed to the container itself is excluded from TPROXY, so the
SOCKS listener and other local services remain reachable.

## Image

```console
docker pull killdns/xray-socks5-router:0.1.0
```

Supported platforms:

- `linux/amd64`
- `linux/arm64`
- `linux/arm/v7`

The image currently contains Xray Core `26.7.28` and HevSocks5Server `2.13.1`.

## What L3 gateway means

An upstream router sends selected IP traffic to the container IP as its next
hop. The container transparently intercepts TCP and UDP with Linux TPROXY and
passes those flows to the Xray outbound from `/etc/xray/config.json`.

This is not an L2 bridge. It does not transport Ethernet frames or extend a
broadcast domain between Docker networks. ICMP and non-TCP/UDP IP protocols are not proxied,
so `ping` is not a useful gateway test. DNS is supported because it uses UDP or
TCP.

SOCKS5 is a separate application-level input. You can use either mode or both
at the same time.

## Requirements

- Docker Engine with Linux containers;
- an Xray client configuration mounted read-only;
- `NET_ADMIN` and `NET_RAW` capabilities;
- the sysctls shown in the Compose example;
- one network for routed client traffic and one network for the Xray underlay;
- an upstream route or policy-routing rule that points selected traffic to the
  container's inbound IP.

The image does not require privileged mode or access to the Docker socket.

## Quick start

### 1. Create the Xray configuration

The container reads `/etc/xray/config.json`. Keep the TPROXY inbound on the same
port as `TPROXY_PORT`, which defaults to `12345`.

The source repository includes a Python 3.10+ generator for VLESS share URIs:

```console
python3 tools/vless_to_config.py \
  --uri-file ./vless-link.txt \
  --output ./config/config.json
```

`vless-link.txt` must contain exactly one non-empty `vless://...` line. Prefer
`--uri-file` or `--stdin`; passing a secret URI with `--uri` may leave it in
shell history. Existing output is replaced only when `--force` is supplied.

The generator supports RAW (`type=tcp`), WebSocket, gRPC `gun`/`multi`,
HTTPUpgrade, XHTTP, and current mKCP settings. It supports `none`, TLS, and
compatible REALITY security. Removed mKCP `seed`/`headerType` options, duplicate
parameters, and unknown parameters are rejected instead of being silently
ignored.

For manual configuration, start with this structure and replace every uppercase
placeholder:

```json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "SERVER_ADDRESS",
            "port": 443,
            "users": [
              {
                "id": "VLESS_UUID",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "method": "raw",
        "security": "reality",
        "realitySettings": {
          "serverName": "REALITY_SNI",
          "fingerprint": "chrome",
          "password": "REALITY_PASSWORD",
          "shortId": "REALITY_SHORT_ID",
          "spiderX": "/"
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["tproxy-in"],
        "outboundTag": "proxy"
      }
    ]
  }
}
```

For current Xray releases, VLESS URI `type=tcp` maps to
`streamSettings.method: raw`, and REALITY `pbk` maps to
`realitySettings.password`. See the current
[VLESS share URI proposal](https://github.com/XTLS/Xray-core/discussions/716)
and [Xray transport configuration](https://github.com/XTLS/Xray-docs-next/blob/main/docs/en/config/transport.md).

### 2. Prepare the Docker networks

The Compose example expects two ordinary user-defined Docker networks. The
underlay network supplies the default route; the transit network receives
routed client traffic.

Example bridge networks using documentation-only addresses:

```console
docker network create --driver bridge \
  --subnet 192.0.2.0/24 \
  --gateway 192.0.2.1 \
  transit_in

docker network create --driver bridge \
  --subnet 198.51.100.0/24 \
  --gateway 198.51.100.1 \
  underlay_out
```

Replace the subnets and gateways. The addresses above come from TEST-NET ranges
and are not deployment values. No parent device is required.

### 3. Start the gateway

Save the following as `compose.yaml` next to `config/config.json`:

```yaml
name: xray-socks5-router

services:
  gateway:
    image: killdns/xray-socks5-router:0.1.0
    container_name: xray-socks5-router
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - NET_RAW
    security_opt:
      - no-new-privileges:true
    sysctls:
      net.ipv4.ip_forward: "1"
      net.ipv4.conf.all.rp_filter: "0"
      net.ipv4.conf.default.rp_filter: "0"
      net.ipv4.conf.all.accept_local: "1"
      net.ipv4.tcp_l3mdev_accept: "1"
      net.ipv4.udp_l3mdev_accept: "1"
    environment:
      INBOUND_INTERFACE: ${INBOUND_INTERFACE:-}
      INBOUND_GATEWAY: ${INBOUND_GATEWAY:-}
      OUTBOUND_INTERFACE: ${OUTBOUND_INTERFACE:-}
      OUTBOUND_GATEWAY: ${OUTBOUND_GATEWAY:-}
      RETURN_CIDRS: ${RETURN_CIDRS:-}
      ENABLE_SOCKS: "1"
      SOCKS_BIND: 0.0.0.0
      SOCKS_PORT: "1080"
      SOCKS_ALLOW_NO_AUTH: "1"
      SOCKS_DNS_SERVER: 1.1.1.1
      SOCKS_UDP_PORT_MIN: "20000"
      SOCKS_UDP_PORT_MAX: "20999"
      SOCKS_UDP_ADVERTISE_IP: ${INBOUND_ADDRESS}
    volumes:
      - ./config/config.json:/etc/xray/config.json:ro
    networks:
      underlay_out:
        ipv4_address: ${OUTBOUND_ADDRESS}
        gw_priority: 1
      transit_in:
        ipv4_address: ${INBOUND_ADDRESS}

networks:
  transit_in:
    name: transit_in
    external: true
  underlay_out:
    name: underlay_out
    external: true
```

Save the deployment values in `.env`:

```dotenv
INBOUND_ADDRESS=192.0.2.2
INBOUND_GATEWAY=
RETURN_CIDRS=

OUTBOUND_ADDRESS=198.51.100.2
OUTBOUND_GATEWAY=
```

Interface names and the outbound gateway are normally detected automatically.
Set `INBOUND_GATEWAY` only when `RETURN_CIDRS` contains networks behind another
router on the transit side.

Then start the container:

```console
docker compose up -d
```

Do not commit `.env`, the VLESS share URI, or the generated Xray configuration.

### 4. Route traffic to the container

On the upstream router, use `192.0.2.2` as the next hop for the clients,
destinations, or policy-routing table that should use Xray. `RETURN_CIDRS` must
contain networks located behind the inbound gateway so replies return through
the same router.

For example, a Linux router can send one documentation-only destination prefix
to the gateway with:

```console
ip route add 203.0.113.0/24 via 192.0.2.2
```

Production policy-routing syntax depends on the upstream router. Avoid replacing
its main default route until the selected path has been tested.

## Verify the deployment

Check container health and startup logs:

```console
docker compose ps
docker compose logs gateway
```

The container validates the Xray JSON before applying routing and firewall
rules. A healthy container has both Xray and HevSocks5Server running, the SOCKS
TCP port listening, the VRF present, and both policy-routing rules installed.

Test SOCKS5 from a client that can reach the container IP:

```console
curl --proxy socks5h://192.0.2.2:1080 \
  --proxy-user 'proxy-user:replace-with-your-password' \
  https://example.com/
```

Test L3 transit with a TCP, UDP, or DNS request from a routed client. Do not use
`ping`: ICMP is outside this gateway's TPROXY path.

## SOCKS5 access

Authentication is required by default. Set both `SOCKS_USER` and
`SOCKS_PASSWORD`. If either value is missing, the container refuses to start.

To run without authentication on a trusted isolated network, leave both values
empty and set:

```yaml
environment:
  SOCKS_ALLOW_NO_AUTH: "1"
```

Never expose an unauthenticated SOCKS listener to the Internet. When clients
connect directly to the container IP, Docker host port publishing is not needed.
For access from outside the Docker host, publish both the TCP listener and the
configured UDP relay range:

```yaml
ports:
  - "1080:1080/tcp"
  - "20000-20999:20000-20999/udp"
```

Set `SOCKS_UDP_ADVERTISE_IP` to an address reachable by SOCKS clients whenever
the address inferred by HevSocks5Server would be wrong because of NAT or port
publishing.

## Configuration reference

### Routing and Xray

| Variable | Default | Description |
|---|---|---|
| `XRAY_CONFIG` | `/etc/xray/config.json` | Xray configuration path inside the container |
| `INBOUND_INTERFACE` | detected non-default interface | Interface receiving routed client traffic |
| `INBOUND_GATEWAY` | empty | Required when `RETURN_CIDRS` is set |
| `OUTBOUND_INTERFACE` | detected default interface | Interface used by the Xray underlay |
| `OUTBOUND_GATEWAY` | detected default gateway | Gateway used by the Xray underlay |
| `RETURN_CIDRS` | empty | Comma-separated client networks routed through the inbound gateway |
| `LOCAL_BYPASS_CIDRS` | reserved and private IPv4 ranges | Destinations excluded from TPROXY |
| `TPROXY_PORT` | `12345` | Must match the Xray TPROXY inbound port |
| `TPROXY_MARK` | `0x1/0x1` | Packet mark used by transparent interception |
| `TPROXY_TABLE` | `100` | Policy-routing table for TPROXY traffic |
| `TPROXY_PRIORITY` | `100` | Priority of the TPROXY policy rule |
| `IPTABLES_BIN` | `iptables` | May be changed to `iptables-legacy` |

`LOCAL_BYPASS_CIDRS` defaults to:

```text
0.0.0.0/8,10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.168.0.0/16,224.0.0.0/4,240.0.0.0/4
```

Replace this list only when you understand which local destinations must bypass
or enter Xray. Changing it can proxy management networks or create routing
loops.

### SOCKS5

| Variable | Default | Description |
|---|---|---|
| `ENABLE_SOCKS` | `1` | Start HevSocks5Server when set to `1` |
| `SOCKS_BIND` | `0.0.0.0` | SOCKS TCP and UDP listening address |
| `SOCKS_PORT` | `1080` | SOCKS5 TCP port; valid range is 1024-65535 |
| `SOCKS_USER` | empty | SOCKS username; set together with `SOCKS_PASSWORD` |
| `SOCKS_PASSWORD` | empty | SOCKS password; set together with `SOCKS_USER` |
| `SOCKS_ALLOW_NO_AUTH` | `0` | Explicitly allow operation without credentials |
| `SOCKS_DNS_SERVER` | `1.1.1.1` | Resolver written to the container's `resolv.conf` |
| `SOCKS_WORKERS` | `2` | HevSocks5Server worker count |
| `SOCKS_UDP_PORT_MIN` | `20000` | First UDP relay port; valid range starts at 1024 |
| `SOCKS_UDP_PORT_MAX` | `20999` | Last UDP relay port; must not be below the minimum |
| `SOCKS_UDP_ADVERTISE_IP` | empty | Reachable IPv4 address returned for UDP `ASSOCIATE` |

SOCKS credentials must be supplied together, must not contain control
characters, and must not exceed 255 characters each.

### Advanced SOCKS injection

These settings control the internal VRF/veth path that forces Hev outbound
traffic into Xray. Most deployments should keep the defaults.

| Variable | Default | Description |
|---|---|---|
| `SOCKS_ROUTE_MARK` | `0x2/0x2` | Mark assigned to traffic created by the Hev process |
| `SOCKS_ROUTE_CLEAR_MARK` | `0x0/0x2` | Mask used before traffic re-enters TPROXY |
| `SOCKS_ROUTE_TABLE` | `200` | Policy-routing table for Hev traffic |
| `SOCKS_ROUTE_PRIORITY` | `90` | Priority of the Hev policy rule |
| `SOCKS_VRF` | `socksvrf` | Internal VRF interface name |
| `SOCKS_VRF_TABLE` | `201` | Routing table attached to the VRF |
| `SOCKS_VETH_OUT` | `hevout` | Hev-facing end of the internal veth pair |
| `SOCKS_VETH_IN` | `hevin` | TPROXY-facing end of the internal veth pair |
| `SOCKS_VETH_OUT_ADDRESS` | `169.254.254.2/30` | Address assigned to `SOCKS_VETH_OUT` |
| `SOCKS_VETH_IN_ADDRESS` | `169.254.254.1/30` | Address assigned to `SOCKS_VETH_IN` |
| `SOCKS_VETH_GATEWAY` | `169.254.254.1` | Next hop in the Hev policy-routing table |

Do not reuse the TPROXY mark/table or address space for the SOCKS injection path.

## Troubleshooting

### The container exits immediately

Read `docker compose logs gateway`. Startup stops before applying network
rules when:

- `/etc/xray/config.json` is missing, empty, or invalid;
- SOCKS credentials are incomplete and `SOCKS_ALLOW_NO_AUTH` is not `1`;
- more than one possible inbound interface exists and `INBOUND_INTERFACE` is empty;
- `RETURN_CIDRS` is set but `INBOUND_GATEWAY` is empty;
- an interface, gateway, capability, sysctl, or iptables backend is unavailable.

Validate the mounted file with the image itself:

```console
docker run --rm \
  --mount type=bind,src="$PWD/config/config.json",dst=/etc/xray/config.json,readonly \
  --entrypoint xray \
  killdns/xray-socks5-router:0.1.0 \
  run -test -config /etc/xray/config.json
```

### SOCKS TCP works but UDP fails

Ensure the full `SOCKS_UDP_PORT_MIN` through `SOCKS_UDP_PORT_MAX` range is
reachable and, when Docker ports are used, published as UDP. Set
`SOCKS_UDP_ADVERTISE_IP` to the client-reachable address.

### Routed traffic does not return

Check the upstream route, `INBOUND_INTERFACE`, `INBOUND_GATEWAY`, and
`RETURN_CIDRS`. Client networks behind the inbound router need an explicit
return route inside the container. Also verify that `TPROXY_PORT` matches the
port of the `dokodemo-door` inbound in the mounted Xray configuration.

### Local destinations bypass Xray

This is the default behavior. Private, loopback, link-local, multicast, and
other reserved IPv4 ranges are listed in `LOCAL_BYPASS_CIDRS`. Adjust the list
only if intentionally proxying one of those ranges.

### `ping` does not use the tunnel

Expected. The gateway transparently handles TCP and UDP, not ICMP.

## Security

- Mount the Xray configuration read-only.
- Keep VLESS UUIDs, REALITY parameters, and SOCKS credentials out of image
  layers, Compose files, logs, and version control.
- Protect the environment file: the image currently reads SOCKS credentials
  from environment variables.
- Do not enable unauthenticated SOCKS on an untrusted network.
- Grant only `NET_ADMIN` and `NET_RAW`; do not use privileged mode.
- Restrict access to the inbound and SOCKS interfaces with the upstream
  firewall.

## Health check

The built-in health check verifies:

- the Xray process;
- the transparent-routing policy rule;
- when SOCKS is enabled, the Hev process, TCP listener, internal VRF, and Hev
  policy rule.

The default health-check interval is 30 seconds, with a 5-second timeout, a
15-second startup grace period, and three retries.

## Upstream projects and licenses

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core), MPL-2.0
- [heiher/hev-socks5-server](https://github.com/heiher/hev-socks5-server), MIT
- [Alpine Linux](https://www.alpinelinux.org/about/) packages under their
  respective licenses

The HevSocks5Server license is included in the image at
`/usr/share/licenses/hev-socks5-server/LICENSE`.
