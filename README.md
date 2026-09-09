# Xray SOCKS5 Router

[Русский](README_RU.md) ·
[Docker Hub](https://hub.docker.com/r/killdns/xray-socks5-router) ·
[Docker Hub README](README_DOCKERHUB.md)

A multi-platform Docker image that acts as an L3 gateway for routed TCP, UDP,
and DNS traffic through Xray. It also provides a SOCKS5 frontend powered by
[HevSocks5Server](https://github.com/heiher/hev-socks5-server).

Supported platforms:

- `linux/amd64` — x86-64;
- `linux/arm64` — ARM64/AArch64;
- `linux/arm/v7` — 32-bit ARMv7.

## What makes it an L3 gateway

In gateway mode, the container receives IP packets on its inbound interface and
routes TCP and UDP flows through Xray. An upstream router uses the container IP
as the next hop for selected client networks or policy-routing tables.

This is not an L2 bridge. It does not carry Ethernet frames, extend a broadcast
domain, or bridge Docker networks. Xray TPROXY handles TCP and UDP, so
ICMP and other IP protocols are not proxied; `ping` is not a valid gateway test.
DNS is carried as TCP or UDP traffic.

SOCKS5 is an additional application-level entry point. Connections created by
HevSocks5Server are forced back into the same L3 Xray path instead of escaping
through the regular underlay route.

## Why this image exists

The upstream Xray image contains Xray itself, but not the networking setup
required for a transit gateway. This project adds:

- transparent TCP and UDP interception with TPROXY;
- bypass for services listening on the container's own addresses;
- policy routing and NAT;
- HevSocks5Server with `CONNECT` and `UDP ASSOCIATE`;
- forced injection of Hev outbound traffic into Xray;
- health checks and coordinated process shutdown;
- builds for three CPU architectures.

## SOCKS traffic path

```text
SOCKS client
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
VLESS/REALITY or another outbound from config.json
```

The internal VRF and veth loop make the kernel re-enter the inbound network
path. Without them, Linux could use a local-route shortcut and Hev would connect
through the container's regular default route, bypassing Xray. The Compose
settings `accept_local` and `*_l3mdev_accept` are required for this loop.

Replies to the SOCKS client are excluded from the injection rule. Only
connections initiated by Hev toward remote destinations, including its DNS
queries, enter the Xray path.

## Component versions

- Xray Core `26.7.28`, copied from the digest-pinned upstream multi-platform
  image.
- HevSocks5Server `2.13.1`, built statically from a release tarball after an
  SHA-256 verification.
- Alpine `3.24`, pinned by multi-platform manifest digest.

Update a component version together with its digest or checksum, then verify all
supported architectures.

## Quick start

1. Create two ordinary user-defined Docker bridge networks, or reuse existing
   networks, for the transit side and the Xray underlay side.
2. In `examples`, copy `.env.example` to `.env` and replace every example
   network name, address, and gateway with values from your deployment.
3. Generate `config/config.json` from a VLESS share URI, or copy and edit the
   example configuration manually, as described below.
4. Start the Compose project. The Xray configuration is mounted read-only at
   `/etc/xray/config.json`.

Containers on the transit network can route directly to the gateway IP. To use
SOCKS5 from outside the Docker host, publish or forward the SOCKS TCP port and
UDP relay range.

The underlay network must provide the container's default route. The Compose
example sets `gw_priority` for this. Interface names are detected automatically:
the default-route interface is the underlay, and the other IPv4 interface is
the transit side. Set `INBOUND_INTERFACE` or `OUTBOUND_INTERFACE` only when the
container has more than two external interfaces or detection is ambiguous.

## Xray connection configuration

Xray uses a JSON configuration rather than a `vless://...` URI directly. This
repository includes a host-side generator that converts one share URI into the
complete gateway configuration, including the TPROXY inbound and routing rule.
The generator is a development tool and is not included in the runtime image.
It uses only the Python 3.10+ standard library.

Save one VLESS share URI as the only non-empty line in `vless-link.txt`, then run
from the repository root:

```sh
python3 tools/vless_to_config.py \
  --uri-file ./vless-link.txt \
  --output examples/config/config.json
```

On Windows PowerShell, use:

```powershell
python .\tools\vless_to_config.py `
  --uri-file .\vless-link.txt `
  --output .\examples\config\config.json
```

The input can also be read from a pipe with `--stdin`. `--uri` is available for
quick tests, but it may save the entire URI in shell history. Use `--force` to
replace an existing output file. The generator does not echo the URI or its
credentials; avoid `--output -` unless deliberately printing the configuration
to standard output.

The generated file supports VLESS over RAW (`type=tcp`), WebSocket, gRPC
`gun`/`multi`, HTTPUpgrade, XHTTP, and mKCP, with `none`, TLS, or compatible
REALITY transport security. Current `fm` finalmask JSON is supported; removed
mKCP `seed` and non-empty `headerType` settings are rejected. Duplicate,
unknown, or incompatible parameters are also rejected rather than silently
producing a configuration that connects differently from the share URI. Legacy
`type=http` and gRPC `mode=guna` require manual configuration.

The mapping follows the current
[Xray VLESS share URI proposal](https://github.com/XTLS/Xray-core/discussions/716)
and [transport configuration](https://github.com/XTLS/Xray-docs-next/blob/main/docs/en/config/transport.md).

Important current field mappings are:

| VLESS URI component | Generated `config.json` field |
|---|---|
| `vless://UUID@...` | `settings.vnext[0].users[0].id` |
| host name or IP after `@` | `settings.vnext[0].address` |
| port after the server name | `settings.vnext[0].port` |
| `flow` | `settings.vnext[0].users[0].flow` |
| `type` | `streamSettings.method` |
| `security` | `streamSettings.security` |
| `sni` | TLS/REALITY `serverName` |
| `fp` | TLS/REALITY `fingerprint` |
| `pbk` | `realitySettings.password` |
| `sid` | `realitySettings.shortId` |
| `pqv` | `realitySettings.mldsa65Verify` |
| `spx` | `realitySettings.spiderX` |

For a manual configuration, copy
[`examples/config/config.example.json`](examples/config/config.example.json) to
`examples/config/config.json` and replace the placeholders. Keep the
`dokodemo-door` TPROXY inbound on port `12345` unless `TPROXY_PORT` is changed
to the same value. The working configuration and common VLESS-link filenames
are ignored by Git because they contain credentials and connection parameters.

Set the host-side configuration path in `.env`:

```dotenv
XRAY_CONFIG_FILE=./config/config.json
```

Validate the file before starting the gateway:

```sh
docker run --rm \
  --mount type=bind,src="$PWD/config/config.json",dst=/etc/xray/config.json,readonly \
  --entrypoint xray \
  killdns/xray-socks5-router:0.1.0 \
  run -test -config /etc/xray/config.json
```

A valid configuration exits with status `0`. Normal container startup performs
the same validation before applying any routing or firewall rules.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `XRAY_CONFIG` | `/etc/xray/config.json` | Configuration path inside the container |
| `INBOUND_INTERFACE` | auto-detected | Non-default IPv4 interface receiving routed client traffic |
| `INBOUND_GATEWAY` | empty | Required only when `RETURN_CIDRS` is set |
| `OUTBOUND_INTERFACE` | auto-detected | Xray underlay interface |
| `OUTBOUND_GATEWAY` | auto-detected | Regular container default gateway |
| `RETURN_CIDRS` | empty | Comma-separated networks returned through the inbound interface |
| `LOCAL_BYPASS_CIDRS` | reserved and private ranges | Destinations that bypass TPROXY |
| `TPROXY_PORT` | `12345` | Port of the Xray TPROXY inbound |
| `ENABLE_SOCKS` | `1` | Start HevSocks5Server |
| `SOCKS_BIND` | `0.0.0.0` | SOCKS5 listening address |
| `SOCKS_PORT` | `1080` | SOCKS5 TCP port |
| `SOCKS_UDP_PORT_MIN/MAX` | `20000` / `20999` | UDP relay port range |
| `SOCKS_UDP_ADVERTISE_IP` | empty | UDP relay address reported to the client |
| `SOCKS_DNS_SERVER` | `1.1.1.1` | Resolver used inside the container |
| `SOCKS_USER/PASSWORD` | empty | Optional SOCKS5 credentials |
| `SOCKS_ALLOW_NO_AUTH` | `0` | Explicitly allow operation without credentials |
| `SOCKS_VRF` | `socksvrf` | Internal VRF used to inject SOCKS traffic into TPROXY |
| `IPTABLES_BIN` | `iptables` | May be changed to `iptables-legacy` |

When credentials are not configured, the container deliberately refuses to
start unless `SOCKS_ALLOW_NO_AUTH=1` is set.

## Build and test

Build for the native platform:

```sh
docker build -t xray-socks5-router:dev .
```

Verify all supported platforms:

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7 \
  --pull \
  .
```

Run the native TCP and UDP integration test:

```sh
./tests/smoke.sh
```

## Security

- The container requires `NET_ADMIN` and `NET_RAW`, but not privileged mode.
- Mount the Xray configuration read-only and never commit it to the repository.
- Never expose an unauthenticated SOCKS listener to an untrusted network.
- The Dockerfile pins upstream image manifests and verifies the Hev source
  archive checksum.

## Upstream projects

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [heiher/hev-socks5-server](https://github.com/heiher/hev-socks5-server)
