# Xray SOCKS5 Router

[Docker Hub](https://hub.docker.com/r/killdns/xray-socks5-router) ·
[Русская документация](README_RU.md) ·
[Docker Hub README](README_DOCKERHUB.md)

A multi-platform Docker image that provides two independent entry points to an
Xray outbound:

- an L3 gateway for routed IPv4 traffic;
- a HevSocks5Server frontend with TCP `CONNECT` and UDP `ASSOCIATE`.

Supported platforms:

- `linux/amd64` — x86_64;
- `linux/arm64` — AArch64;
- `linux/arm/v7` — 32-bit ARMv7, including RouterOS containers on compatible
  MikroTik devices.

## Routing modes

| Mode | Use it on | Kernel requirement | Routed traffic |
|---|---|---|---|
| `tproxy` | Ordinary Linux Docker hosts | working iptables/nftables TPROXY | TCP and UDP |
| `tun` | RouterOS containers and Linux hosts | `/dev/net/tun`, `NET_ADMIN`, policy routing | TCP, UDP, and Xray TUN ICMP echo behavior |

`tproxy` remains the default for backward compatibility. `tun` does not use
iptables or nftables for interception, so it works on RouterOS kernels that do
not expose the TPROXY target to containers.

This is an L3 router, not an Ethernet bridge. Clients must route selected IP
traffic to the container address. The image does not extend a VLAN, broadcast
domain, or Docker network across the Xray connection.

### TUN traffic path

```text
routed client/network
        |
        v
container inbound interface
        |
        | iif policy rule -> table 100
        v
xray0 (Xray TUN inbound)
        |
        v
Xray outbound from config.json

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

Xray runs under a dedicated UID with only the ambient `CAP_NET_ADMIN` capability.
All other container-local traffic uses the TUN policy table. Xray's own upstream
sockets keep using `main`, preventing the proxy connection from being routed
back into its own TUN interface.

### TPROXY SOCKS path

```text
SOCKS5 client -> HevSocks5Server :1080
        |
        | UID mark 0x2 -> policy table 200
        v
internal VRF/veth loop
        |
        | TPROXY mark 0x1 -> policy table 100
        v
Xray dokodemo-door :12345 -> Xray outbound
```

The VRF and veth pair exist only inside the container. They are not Docker
networks, VLANs, or host-side interfaces.

## Included software

- Xray Core `26.7.28` from the digest-pinned upstream image;
- HevSocks5Server `2.13.1`, built statically from a checksum-verified release;
- Alpine `3.24`, pinned by multi-platform manifest digest.

## Create the Xray configuration

The image reads `/etc/xray/config.json`. The repository includes a host-side
generator for one `vless://` share URI. Python 3.10 or newer is required only on
the machine generating the file.

TPROXY configuration:

```bash
python3 tools/vless_to_config.py \
  --uri-file ./vless-link.txt \
  --routing-mode tproxy \
  --output ./config/config.json
```

Native TUN configuration:

```bash
python3 tools/vless_to_config.py \
  --uri-file ./vless-link.txt \
  --routing-mode tun \
  --tun-interface xray0 \
  --tun-mtu 1400 \
  --output ./config/config.json
```

PowerShell uses the same options:

```powershell
python .\tools\vless_to_config.py `
  --uri-file .\vless-link.txt `
  --routing-mode tun `
  --output .\config\config.json
```

The generator refuses to overwrite a file unless `--force` is supplied. Avoid
`--uri` because command-line arguments can be retained in shell history. The
share URI, generated JSON, UUID, REALITY parameters, and SOCKS credentials must
not be committed.

Manual configuration is also supported; start with
[`examples/config/config.example.json`](examples/config/config.example.json).

### Reuse an existing TPROXY config in TUN mode

When `ROUTING_MODE=tun` is selected and the mounted config contains a TPROXY
`dokodemo-door` inbound, the entrypoint converts that inbound to TUN in an
ephemeral file under `/run`. The mounted config remains unchanged. Its inbound
tag is preserved, so existing routing rules continue to match.

If the mounted config already has a TUN inbound, it is used as-is. Its interface
name must match `TUN_INTERFACE`.

## Docker deployment

Start from [`examples/compose.yaml`](examples/compose.yaml) for the default
TPROXY mode. It expects separate inbound and outbound Docker networks so the
container can be used as a routed next hop.

For TUN mode, add the TUN device and select the mode:

```yaml
services:
  gateway:
    image: killdns/xray-socks5-router:0.2.1
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      net.ipv4.ip_forward: "1"
      net.ipv4.conf.all.rp_filter: "0"
      net.ipv4.conf.default.rp_filter: "0"
    environment:
      ROUTING_MODE: tun
      TUN_INTERFACE: xray0
      TUN_GATEWAY: 198.18.0.1/30
      TUN_MTU: "1400"
      SOCKS_ALLOW_NO_AUTH: "1"
    volumes:
      - ./config/config.json:/etc/xray/config.json:ro
```

On RouterOS, use `ROUTING_MODE=tun` in the container envlist. The container must
see `/dev/net/tun`; RouterOS 7.23 provides it to containers on supported
hardware. TPROXY mode is not expected to work where the RouterOS kernel omits
the TPROXY netfilter target.

## Network configuration

The entrypoint detects interfaces when possible:

- the interface carrying the original default route becomes the outbound;
- one other global IPv4 interface becomes the inbound;
- with one interface, it is used for both directions.

Set `INBOUND_INTERFACE` and `OUTBOUND_INTERFACE` explicitly when the container
has more than two candidate interfaces or when deterministic naming is needed.
Use `RETURN_CIDRS` with `INBOUND_GATEWAY` for client networks that are not
directly connected to the container.

`LOCAL_BYPASS_CIDRS` is routed directly through the outbound gateway. Connected
routes on the inbound interface are also kept outside Xray so local services,
SOCKS clients, and return traffic remain reachable.

## Configuration reference

### Common routing

| Variable | Default | Purpose |
|---|---|---|
| `XRAY_CONFIG` | `/etc/xray/config.json` | Mounted Xray configuration |
| `ROUTING_MODE` | `tproxy` | `tproxy` or `tun` |
| `INBOUND_INTERFACE` | auto | Interface receiving routed client traffic |
| `INBOUND_GATEWAY` | empty | Next hop for `RETURN_CIDRS` |
| `OUTBOUND_INTERFACE` | default-route interface | Underlay/uplink interface |
| `OUTBOUND_GATEWAY` | default-route gateway | Underlay gateway |
| `RETURN_CIDRS` | empty | Comma-separated client networks returned through the inbound gateway |
| `LOCAL_BYPASS_CIDRS` | reserved/private IPv4 ranges | Destinations routed directly instead of through Xray |

### TUN mode

| Variable | Default | Purpose |
|---|---|---|
| `TUN_INTERFACE` | `xray0` | Xray TUN interface name; must match the config |
| `TUN_GATEWAY` | `198.18.0.1/30` | Address used when converting a TPROXY config |
| `TUN_MTU` | `1400` | MTU used when converting a TPROXY config |
| `TUN_TABLE` | `100` | Policy table for routed L3 traffic |
| `TUN_PRIORITY` | `1000` | Inbound-interface rule priority; must be greater than 200 for RouterOS |
| `TUN_SOCKS_PRIORITY` | `900` | Hev process-UID rule priority; must be greater than 200 |
| `TUN_LOCAL_PRIORITY` | `950` | Rule routing container-local traffic except Xray through TUN |
| `TUN_WAIT_SECONDS` | `15` | Time to wait for Xray to create the TUN interface |

### TPROXY mode

| Variable | Default | Purpose |
|---|---|---|
| `TPROXY_PORT` | `12345` | Port of the Xray transparent inbound |
| `TPROXY_MARK` | `0x1/0x1` | Transparent-interception mark |
| `TPROXY_TABLE` | `100` | Transparent-interception policy table |
| `TPROXY_PRIORITY` | `100` | Transparent-interception rule priority |
| `IPTABLES_BIN` | `iptables` | iptables frontend; `iptables-legacy` can be selected explicitly |

### SOCKS5

| Variable | Default | Purpose |
|---|---|---|
| `ENABLE_SOCKS` | `1` | Start HevSocks5Server |
| `SOCKS_BIND` | `0.0.0.0` | TCP and UDP listen address |
| `SOCKS_PORT` | `1080` | SOCKS5 TCP port |
| `SOCKS_USER` / `SOCKS_PASSWORD` | empty | Optional credentials; both must be set together |
| `SOCKS_ALLOW_NO_AUTH` | `0` | Must be `1` to run without credentials |
| `SOCKS_DNS_SERVER` | `1.1.1.1` | Resolver written to the container's `resolv.conf` |
| `SOCKS_WORKERS` | `2` | Hev worker count |
| `SOCKS_LOG_LEVEL` | `warn` | `debug`, `info`, `warn`, or `error` |
| `SOCKS_UDP_PORT_MIN` / `MAX` | `20000` / `20999` | UDP relay range |
| `SOCKS_UDP_ADVERTISE_IP` | empty | Client-reachable IPv4 address returned by UDP `ASSOCIATE` |

TPROXY-only advanced VRF/veth variables remain backward compatible. See the
entrypoint source before overriding them; TUN mode does not use them.

## Build and test

```bash
docker build -t xray-socks5-router:test .
./tests/smoke.sh
```

Build every supported architecture:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7 \
  -t killdns/xray-socks5-router:0.2.1 \
  .
```

The smoke test verifies container-local TUN traffic, L3 TCP/UDP, and SOCKS5
TCP/UDP in both routing modes.

## Security and limitations

- Mount the Xray configuration read-only.
- Never expose unauthenticated SOCKS to an untrusted network.
- Publish or forward the SOCKS TCP port and the complete UDP relay range only
  when external SOCKS access is required.
- TUN is fail-closed for traffic selected by its policy table: if Xray stops,
  that traffic stops as well.
- Xray TUN ICMP echo indicates that the TUN stack accepted the packet; it is not
  proof that the remote host answered.
- This release configures IPv4 routing. An Xray outbound may use IPv6 internally,
  but IPv6 transit routing is outside the current scope.

See the upstream [Xray TUN documentation](https://github.com/XTLS/Xray-core/blob/v26.7.28/proxy/tun/README.md)
for protocol behavior and limitations.
