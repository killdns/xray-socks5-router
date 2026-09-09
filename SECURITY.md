# Security policy

## Supported versions

Only the latest released image version is supported with security fixes.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose proxy access,
credentials, routing controls, or host networking. Use GitHub private
vulnerability reporting after the repository is published.

Do not include production Xray configuration, UUIDs, private keys, passwords,
REALITY parameters, or packet captures containing private traffic.

## Deployment boundary

The image needs `NET_ADMIN` and `NET_RAW` to configure policy routing, veth, and
TPROXY. It does not require privileged mode or access to the Docker socket.
Unauthenticated SOCKS service is disabled by default.
