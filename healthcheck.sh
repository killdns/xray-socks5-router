#!/bin/sh
set -eu

TPROXY_MARK="${TPROXY_MARK:-0x1/0x1}"
TPROXY_TABLE="${TPROXY_TABLE:-100}"
ENABLE_SOCKS="${ENABLE_SOCKS:-1}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_ROUTE_MARK="${SOCKS_ROUTE_MARK:-0x2/0x2}"
SOCKS_ROUTE_TABLE="${SOCKS_ROUTE_TABLE:-200}"
SOCKS_VRF="${SOCKS_VRF:-socksvrf}"

pidof xray >/dev/null
ip -4 rule show | grep -F "fwmark ${TPROXY_MARK} lookup ${TPROXY_TABLE}" >/dev/null

if [ "$ENABLE_SOCKS" = "1" ]; then
  pidof hev-socks5-server >/dev/null
  ss -lnt | grep -E "[:.]${SOCKS_PORT}[[:space:]]" >/dev/null
  ip link show "$SOCKS_VRF" >/dev/null
  ip -4 rule show | grep -F "fwmark ${SOCKS_ROUTE_MARK} lookup ${SOCKS_ROUTE_TABLE}" >/dev/null
fi
