# Changelog

All notable changes to this project will be documented in this file.

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
