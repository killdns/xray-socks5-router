# Changelog

All notable changes to this project will be documented in this file.

## 0.3.0 - 2026-09-11

- Added runtime `VLESS_URI` configuration generation inside the container.
- Kept mounted `config.json` support unchanged; `VLESS_URI` takes precedence when set.
- Passed URI data to the embedded generator through stdin and removed it from the
  child-process environment before starting Xray.
- Added regression coverage for generated configuration, restrictive file mode,
  invalid-URI handling, and log/environment leak prevention.

## 0.2.1 - 2026-09-09

- Routed container-local IPv4 traffic through Xray in TUN mode while excluding
  only Xray's own upstream sockets to prevent a routing loop.
- Ran Xray under a dedicated unprivileged UID with only the ambient
  `CAP_NET_ADMIN` capability required to create and manage its TUN interface.
- Added a regression test that verifies container-local traffic enters Xray TUN.

## 0.2.0 - 2026-09-09

- Added a RouterOS-compatible native TUN routing mode that does not require the
  netfilter TPROXY target.
- Added automatic, ephemeral conversion of an existing TPROXY `dokodemo-door`
  inbound when `ROUTING_MODE=tun` is selected.
- Added native TUN output to the VLESS configuration generator.
- Added dual-mode L3 TCP/UDP and SOCKS5 TCP/UDP integration coverage.
- Kept multi-platform builds for `linux/amd64`, `linux/arm64`, and
  `linux/arm/v7`.

## 0.1.0 - 2026-09-09

- Added an L3 gateway for routed TCP, UDP, and DNS traffic through Xray.
- Added HevSocks5Server with SOCKS5 CONNECT and UDP ASSOCIATE.
- Injected Hev outbound traffic into Xray through a marked VRF/veth loop.
- Added `linux/amd64`, `linux/arm64`, and `linux/arm/v7` builds.
- Added native TCP/UDP smoke tests and reproducible multi-platform build settings.
- Added a host-side VLESS share URI to `config.json` generator.
- Added a standalone Docker Hub README with deployment and configuration reference.
- Added automatic interface detection for ordinary two-network Docker deployments.
- Excluded traffic to container-local services from transparent interception.
