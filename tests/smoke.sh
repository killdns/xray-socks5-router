#!/bin/sh
set -eu

unset CDPATH
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_PATH="$ROOT_DIR/tests/xray-direct.json"
TUN_CONFIG_PATH="$ROOT_DIR/tests/xray-direct-tun.json"
UDP_TEST_PATH="$ROOT_DIR/tests/socks5_udp_test.py"

case "$(uname -s)" in
  MINGW*|MSYS*)
    CONFIG_PATH="$(cygpath -w "$CONFIG_PATH")"
    TUN_CONFIG_PATH="$(cygpath -w "$TUN_CONFIG_PATH")"
    UDP_TEST_PATH="$(cygpath -w "$UDP_TEST_PATH")"
    export MSYS_NO_PATHCONV=1
    ;;
esac

cd "$ROOT_DIR"

IMAGE="${IMAGE:-xray-socks5-router:test}"
KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-0}"
INBOUND_NETWORK="xray-socks5-router-smoke-in"
OUTBOUND_NETWORK="xray-socks5-router-smoke-out"
ROUTER="xray-socks5-router-smoke-router"
TARGET="xray-socks5-router-smoke-target"
CLIENT="xray-socks5-router-smoke-client"

cleanup() {
  docker rm -f "$ROUTER" "$TARGET" "$CLIENT" >/dev/null 2>&1 || true
  docker network rm "$INBOUND_NETWORK" "$OUTBOUND_NETWORK" >/dev/null 2>&1 || true
}

finish() {
  status="$?"
  trap - EXIT INT TERM HUP
  if [ "$status" -ne 0 ]; then
    docker logs "$ROUTER" 2>/dev/null || true
    docker logs "$TARGET" 2>/dev/null || true
    docker exec "$ROUTER" ip -4 rule show 2>/dev/null || true
    docker exec "$ROUTER" ip -4 route show table all 2>/dev/null || true
    docker exec "$ROUTER" iptables -t mangle -vxnL 2>/dev/null || true
    if [ "$KEEP_ON_FAILURE" = "1" ]; then
      printf '%s\n' "Smoke resources kept for diagnostics"
      exit "$status"
    fi
  fi
  cleanup
  exit "$status"
}

trap finish EXIT INT TERM HUP
cleanup

docker build --pull --tag "$IMAGE" .
docker run --rm --entrypoint sh "$IMAGE" -c \
  'xray version && test -x /usr/local/bin/hev-socks5-server'
docker run --rm \
  --entrypoint xray \
  -v "$TUN_CONFIG_PATH:/etc/xray/config.json:ro" \
  "$IMAGE" run -test -config /etc/xray/config.json
docker pull curlimages/curl:8.16.0 >/dev/null
docker pull python:3.13-alpine >/dev/null

auth_guard_log="$(docker run --rm \
  -v "$CONFIG_PATH:/etc/xray/config.json:ro" \
  "$IMAGE" 2>&1 || true)"
printf '%s\n' "$auth_guard_log" | \
  grep -F 'set SOCKS credentials or explicitly set SOCKS_ALLOW_NO_AUTH=1' >/dev/null

docker network create \
  --subnet 192.0.2.0/24 \
  --gateway 192.0.2.1 \
  "$INBOUND_NETWORK" >/dev/null

docker network create \
  --subnet 198.51.100.0/24 \
  --gateway 198.51.100.1 \
  "$OUTBOUND_NETWORK" >/dev/null

docker run -d \
  --name "$TARGET" \
  --network "$OUTBOUND_NETWORK" \
  --ip 198.51.100.20 \
  alpine:3.24 \
  sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 25\r\nConnection: close\r\n\r\nxray-socks5-router-smoke\n" | nc -l -p 8080; done & while true; do nc -u -l -p 9996 -e cat; done & while true; do nc -u -l -p 9997 -e cat; done & while true; do nc -u -l -p 9998 -e cat; done & while true; do nc -u -l -p 9999 -e cat; done' \
  >/dev/null

docker create \
  --name "$ROUTER" \
  --network "$OUTBOUND_NETWORK" \
  --ip 198.51.100.10 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --security-opt no-new-privileges:true \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.rp_filter=0 \
  --sysctl net.ipv4.conf.default.rp_filter=0 \
  --sysctl net.ipv4.conf.all.accept_local=1 \
  --sysctl net.ipv4.tcp_l3mdev_accept=1 \
  --sysctl net.ipv4.udp_l3mdev_accept=1 \
  -p 127.0.0.1:11080:1080/tcp \
  -p 127.0.0.1:20000-20009:20000-20009/udp \
  -e RETURN_CIDRS= \
  -e LOCAL_BYPASS_CIDRS=0.0.0.0/8,10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.168.0.0/16,198.51.100.10/32,224.0.0.0/4,240.0.0.0/4 \
  -e SOCKS_ALLOW_NO_AUTH=1 \
  -e SOCKS_UDP_PORT_MIN=20000 \
  -e SOCKS_UDP_PORT_MAX=20009 \
  -e SOCKS_UDP_ADVERTISE_IP=127.0.0.1 \
  -v "$CONFIG_PATH:/etc/xray/config.json:ro" \
  "$IMAGE" >/dev/null

docker network connect \
  --gw-priority -1 \
  --ip 192.0.2.10 \
  "$INBOUND_NETWORK" \
  "$ROUTER"
docker start "$ROUTER" >/dev/null

attempt=0
until [ "$(docker inspect --format '{{.State.Health.Status}}' "$ROUTER")" = "healthy" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    docker logs "$ROUTER"
    exit 1
  fi
  sleep 1
done

detected_output="$(docker exec "$ROUTER" ip -4 route show default | \
  awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
detected_input="$(docker exec "$ROUTER" iptables -t mangle -S PREROUTING | \
  awk '$1 == "-A" && $2 == "PREROUTING" && $3 == "-i" && $5 == "-j" && $6 == "XRAY" { print $4; exit }')"
if [ -z "$detected_input" ] || [ -z "$detected_output" ] || \
  [ "$detected_input" = "$detected_output" ]; then
    printf '%s\n' "Ordinary two-network interface auto-detection failed" >&2
    exit 1
fi
docker exec "$ROUTER" ip -4 -o address show dev "$detected_input" | \
  grep -F '192.0.2.10/24' >/dev/null

l3_result="$(docker run --rm \
  --name "$CLIENT" \
  --network "$INBOUND_NETWORK" \
  --ip 192.0.2.20 \
  --cap-add NET_ADMIN \
  alpine:3.24 \
  sh -c 'ip route add 198.51.100.20/32 via 192.0.2.10 && wget -T 10 -qO- http://198.51.100.20:8080/')"
[ "$l3_result" = "xray-socks5-router-smoke" ]

l3_udp_result="$(docker run --rm \
  --name "$CLIENT" \
  --network "$INBOUND_NETWORK" \
  --ip 192.0.2.20 \
  --cap-add NET_ADMIN \
  alpine:3.24 \
  sh -c 'ip route add 198.51.100.20/32 via 192.0.2.10 && { printf l3-udp-smoke | nc -u -w 2 198.51.100.20 9998 || true; }')"
[ "$l3_udp_result" = "l3-udp-smoke" ]

result="$(curl --fail --silent --show-error --max-time 10 \
  --socks5-hostname 127.0.0.1:11080 \
  http://198.51.100.20:8080/)"
[ "$result" = "xray-socks5-router-smoke" ]

udp_tproxy_packets() {
  docker exec "$ROUTER" sh -c \
    'iptables -t mangle -vxnL XRAY | awk '\''$3 == "TPROXY" && $4 == "udp" { packets += $1 } END { print packets + 0 }'\'''
}

udp_packets_before="$(udp_tproxy_packets)"
if command -v python3 >/dev/null 2>&1; then
  python3 tests/socks5_udp_test.py
elif command -v python >/dev/null 2>&1; then
  python tests/socks5_udp_test.py
else
  printf '%s\n' "Python 3 is required for the SOCKS5 UDP test" >&2
  exit 1
fi
udp_packets_after="$(udp_tproxy_packets)"
[ "$udp_packets_after" -gt "$udp_packets_before" ] || {
  printf '%s\n' "SOCKS5 UDP traffic bypassed the Xray TPROXY path" >&2
  exit 1
}

docker exec "$ROUTER" sh -c \
  'iptables -t mangle -vxnL XRAY | awk '\''$3 == "TPROXY" && ($1 + 0) > 0 { found = 1 } END { exit(found ? 0 : 1) }'\'''

docker rm -f "$ROUTER" >/dev/null

docker create \
  --name "$ROUTER" \
  --network "$OUTBOUND_NETWORK" \
  --ip 198.51.100.10 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --device /dev/net/tun \
  --security-opt no-new-privileges:true \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.rp_filter=0 \
  --sysctl net.ipv4.conf.default.rp_filter=0 \
  -e ROUTING_MODE=tun \
  -e RETURN_CIDRS= \
  -e SOCKS_ALLOW_NO_AUTH=1 \
  -e SOCKS_UDP_PORT_MIN=20000 \
  -e SOCKS_UDP_PORT_MAX=20009 \
  -e SOCKS_UDP_ADVERTISE_IP=192.0.2.10 \
  -v "$CONFIG_PATH:/etc/xray/config.json:ro" \
  "$IMAGE" >/dev/null

docker network connect \
  --gw-priority -1 \
  --ip 192.0.2.10 \
  "$INBOUND_NETWORK" \
  "$ROUTER"
docker start "$ROUTER" >/dev/null

attempt=0
until [ "$(docker inspect --format '{{.State.Health.Status}}' "$ROUTER")" = "healthy" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    docker logs "$ROUTER"
    exit 1
  fi
  sleep 1
done

tun_packets_before="$(docker exec "$ROUTER" \
  cat /sys/class/net/xray0/statistics/rx_packets)"

l3_tun_result="$(docker run --rm \
  --name "$CLIENT" \
  --network "$INBOUND_NETWORK" \
  --ip 192.0.2.20 \
  --cap-add NET_ADMIN \
  alpine:3.24 \
  sh -c 'ip route add 198.51.100.20/32 via 192.0.2.10 && wget -T 10 -qO- http://198.51.100.20:8080/')"
[ "$l3_tun_result" = "xray-socks5-router-smoke" ]

l3_tun_udp_result="$(docker run --rm \
  --name "$CLIENT" \
  --network "$INBOUND_NETWORK" \
  --ip 192.0.2.21 \
  --cap-add NET_ADMIN \
  alpine:3.24 \
  sh -c 'ip route add 198.51.100.20/32 via 192.0.2.10 && { printf l3-tun-udp-smoke | nc -u -w 5 198.51.100.20 9997 || true; }')"
[ "$l3_tun_udp_result" = "l3-tun-udp-smoke" ] || {
  printf '%s\n' "Unexpected TUN L3 UDP response: <$l3_tun_udp_result>" >&2
  exit 1
}

sleep 2

set +e
socks_tun_result="$(docker run --rm \
  --name "$CLIENT" \
  --network "$INBOUND_NETWORK" \
  --ip 192.0.2.22 \
  curlimages/curl:8.16.0 \
  --fail --silent --show-error --max-time 10 \
  --retry 3 --retry-all-errors --retry-delay 1 \
  --socks5-hostname 192.0.2.10:1080 \
  http://198.51.100.20:8080/ 2>&1)"
socks_tun_status="$?"
set -e
if [ "$socks_tun_status" -ne 0 ] || \
  [ "$socks_tun_result" != "xray-socks5-router-smoke" ]; then
  printf '%s\n' \
    "TUN SOCKS TCP failed (${socks_tun_status}): <$socks_tun_result>" >&2
  exit 1
fi

docker run --rm \
  --name "$CLIENT" \
  --network "$INBOUND_NETWORK" \
  --ip 192.0.2.30 \
  -e SOCKS_HOST=192.0.2.10 \
  -e SOCKS_PORT=1080 \
  -e SOCKS_TARGET_IP=198.51.100.20 \
  -e SOCKS_TARGET_PORT=9996 \
  -v "$UDP_TEST_PATH:/test.py:ro" \
  python:3.13-alpine \
  python /test.py

tun_packets_after="$(docker exec "$ROUTER" \
  cat /sys/class/net/xray0/statistics/rx_packets)"
[ "$tun_packets_after" -gt "$tun_packets_before" ] || {
  printf '%s\n' "TUN traffic did not enter Xray" >&2
  exit 1
}

printf '%s\n' "TPROXY and TUN L3 TCP/UDP plus SOCKS5 TCP/UDP smoke tests passed"
