#!/bin/sh
set -eu

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

XRAY_CONFIG="${XRAY_CONFIG:-/etc/xray/config.json}"
INBOUND_INTERFACE="${INBOUND_INTERFACE:-}"
INBOUND_GATEWAY="${INBOUND_GATEWAY:-}"
OUTBOUND_INTERFACE="${OUTBOUND_INTERFACE:-}"
OUTBOUND_GATEWAY="${OUTBOUND_GATEWAY:-}"
RETURN_CIDRS="${RETURN_CIDRS:-}"
LOCAL_BYPASS_CIDRS="${LOCAL_BYPASS_CIDRS:-0.0.0.0/8,10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.168.0.0/16,224.0.0.0/4,240.0.0.0/4}"

TPROXY_PORT="${TPROXY_PORT:-12345}"
TPROXY_MARK="${TPROXY_MARK:-0x1/0x1}"
TPROXY_TABLE="${TPROXY_TABLE:-100}"
TPROXY_PRIORITY="${TPROXY_PRIORITY:-100}"
IPTABLES_BIN="${IPTABLES_BIN:-iptables}"

ENABLE_SOCKS="${ENABLE_SOCKS:-1}"
SOCKS_BIND="${SOCKS_BIND:-0.0.0.0}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASSWORD="${SOCKS_PASSWORD:-}"
SOCKS_ALLOW_NO_AUTH="${SOCKS_ALLOW_NO_AUTH:-0}"
SOCKS_DNS_SERVER="${SOCKS_DNS_SERVER:-1.1.1.1}"
SOCKS_WORKERS="${SOCKS_WORKERS:-2}"
SOCKS_UDP_PORT_MIN="${SOCKS_UDP_PORT_MIN:-20000}"
SOCKS_UDP_PORT_MAX="${SOCKS_UDP_PORT_MAX:-20999}"
SOCKS_UDP_ADVERTISE_IP="${SOCKS_UDP_ADVERTISE_IP:-}"

SOCKS_ROUTE_MARK="${SOCKS_ROUTE_MARK:-0x2/0x2}"
SOCKS_ROUTE_CLEAR_MARK="${SOCKS_ROUTE_CLEAR_MARK:-0x0/0x2}"
SOCKS_ROUTE_TABLE="${SOCKS_ROUTE_TABLE:-200}"
SOCKS_ROUTE_PRIORITY="${SOCKS_ROUTE_PRIORITY:-90}"
SOCKS_VRF="${SOCKS_VRF:-socksvrf}"
SOCKS_VRF_TABLE="${SOCKS_VRF_TABLE:-201}"
SOCKS_VETH_OUT="${SOCKS_VETH_OUT:-hevout}"
SOCKS_VETH_IN="${SOCKS_VETH_IN:-hevin}"
SOCKS_VETH_OUT_ADDRESS="${SOCKS_VETH_OUT_ADDRESS:-169.254.254.2/30}"
SOCKS_VETH_IN_ADDRESS="${SOCKS_VETH_IN_ADDRESS:-169.254.254.1/30}"
SOCKS_VETH_GATEWAY="${SOCKS_VETH_GATEWAY:-169.254.254.1}"

XRAY_PID=""
SOCKS_PID=""

[ "$(id -u)" -eq 0 ] || fail "container must run as root"
[ -s "$XRAY_CONFIG" ] || fail "Xray config is missing or empty: $XRAY_CONFIG"
command -v "$IPTABLES_BIN" >/dev/null 2>&1 || fail "iptables backend not found: $IPTABLES_BIN"

is_uint "$TPROXY_PORT" || fail "TPROXY_PORT must be numeric"
is_uint "$TPROXY_TABLE" || fail "TPROXY_TABLE must be numeric"
is_uint "$TPROXY_PRIORITY" || fail "TPROXY_PRIORITY must be numeric"

case "$ENABLE_SOCKS" in
  0|1) ;;
  *) fail "ENABLE_SOCKS must be 0 or 1" ;;
esac

if [ "$ENABLE_SOCKS" = "1" ]; then
  is_uint "$SOCKS_PORT" || fail "SOCKS_PORT must be numeric"
  is_uint "$SOCKS_WORKERS" || fail "SOCKS_WORKERS must be numeric"
  is_uint "$SOCKS_UDP_PORT_MIN" || fail "SOCKS_UDP_PORT_MIN must be numeric"
  is_uint "$SOCKS_UDP_PORT_MAX" || fail "SOCKS_UDP_PORT_MAX must be numeric"
  is_uint "$SOCKS_ROUTE_TABLE" || fail "SOCKS_ROUTE_TABLE must be numeric"
  is_uint "$SOCKS_ROUTE_PRIORITY" || fail "SOCKS_ROUTE_PRIORITY must be numeric"
  is_uint "$SOCKS_VRF_TABLE" || fail "SOCKS_VRF_TABLE must be numeric"

  [ "$SOCKS_PORT" -ge 1024 ] && [ "$SOCKS_PORT" -le 65535 ] || fail "invalid SOCKS_PORT"
  [ "$SOCKS_UDP_PORT_MIN" -ge 1024 ] && \
    [ "$SOCKS_UDP_PORT_MAX" -le 65535 ] && \
    [ "$SOCKS_UDP_PORT_MIN" -le "$SOCKS_UDP_PORT_MAX" ] || fail "invalid SOCKS UDP range"

  if [ -n "$SOCKS_USER" ] || [ -n "$SOCKS_PASSWORD" ]; then
    [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASSWORD" ] || \
      fail "SOCKS_USER and SOCKS_PASSWORD must be set together"
  else
    [ "$SOCKS_ALLOW_NO_AUTH" = "1" ] || \
      fail "set SOCKS credentials or explicitly set SOCKS_ALLOW_NO_AUTH=1"
  fi

  if printf '%s%s' "$SOCKS_USER" "$SOCKS_PASSWORD" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "SOCKS credentials must not contain control characters"
  fi
  [ "${#SOCKS_USER}" -le 255 ] && [ "${#SOCKS_PASSWORD}" -le 255 ] || \
    fail "SOCKS credentials must not exceed 255 characters"
fi

/usr/local/bin/xray run -test -config "$XRAY_CONFIG"

detected_default="$(ip -4 route show default | awk 'NR == 1 { print; exit }')"
detected_default_interface="$(printf '%s\n' "$detected_default" | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
detected_default_gateway="$(printf '%s\n' "$detected_default" | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')"

if [ -z "$OUTBOUND_INTERFACE" ]; then
  OUTBOUND_INTERFACE="$detected_default_interface"
fi
if [ -z "$OUTBOUND_GATEWAY" ]; then
  [ "$OUTBOUND_INTERFACE" = "$detected_default_interface" ] || \
    fail "OUTBOUND_GATEWAY is required when OUTBOUND_INTERFACE is not the default-route interface"
  OUTBOUND_GATEWAY="$detected_default_gateway"
fi
[ -n "$OUTBOUND_INTERFACE" ] || fail "cannot detect OUTBOUND_INTERFACE"
[ -n "$OUTBOUND_GATEWAY" ] || fail "cannot detect OUTBOUND_GATEWAY"

if [ -z "$INBOUND_INTERFACE" ]; then
  detected_inbound_interface=""
  for candidate in $(
    ip -4 -o address show scope global | \
      awk -v outbound="$OUTBOUND_INTERFACE" '
        {
          interface = $2
          sub(/@.*/, "", interface)
          if (interface != "lo" && interface != outbound) print interface
        }
      ' | sort -u
  ); do
    [ -z "$detected_inbound_interface" ] || \
      fail "multiple inbound interfaces detected; set INBOUND_INTERFACE explicitly"
    detected_inbound_interface="$candidate"
  done
  INBOUND_INTERFACE="${detected_inbound_interface:-$OUTBOUND_INTERFACE}"
fi

return_cidrs_compact="$(printf '%s' "$RETURN_CIDRS" | tr -d ' ,')"
if [ -n "$return_cidrs_compact" ] && [ -z "$INBOUND_GATEWAY" ]; then
  fail "INBOUND_GATEWAY is required when RETURN_CIDRS is set"
fi

ip link show dev "$INBOUND_INTERFACE" >/dev/null 2>&1 || \
  fail "INBOUND_INTERFACE does not exist: $INBOUND_INTERFACE"
ip link show dev "$OUTBOUND_INTERFACE" >/dev/null 2>&1 || \
  fail "OUTBOUND_INTERFACE does not exist: $OUTBOUND_INTERFACE"
ip link set dev "$INBOUND_INTERFACE" up
ip link set dev "$OUTBOUND_INTERFACE" up

while ip -4 route del default 2>/dev/null; do :; done
ip -4 route add default via "$OUTBOUND_GATEWAY" dev "$OUTBOUND_INTERFACE"

old_ifs="$IFS"
IFS=','
for cidr in $RETURN_CIDRS; do
  cidr="$(printf '%s' "$cidr" | tr -d ' ')"
  [ -n "$cidr" ] || continue
  ip -4 route replace "$cidr" via "$INBOUND_GATEWAY" dev "$INBOUND_INTERFACE"
done
IFS="$old_ifs"

while ip -4 rule del fwmark "$TPROXY_MARK" table "$TPROXY_TABLE" 2>/dev/null; do :; done
ip -4 rule add priority "$TPROXY_PRIORITY" fwmark "$TPROXY_MARK" table "$TPROXY_TABLE"
ip -4 route replace local 0.0.0.0/0 dev lo table "$TPROXY_TABLE"

while "$IPTABLES_BIN" -t mangle -D PREROUTING -i "$INBOUND_INTERFACE" -j XRAY 2>/dev/null; do :; done
"$IPTABLES_BIN" -t mangle -N XRAY 2>/dev/null || "$IPTABLES_BIN" -t mangle -F XRAY
"$IPTABLES_BIN" -t mangle -A XRAY -m addrtype --dst-type LOCAL -j RETURN

old_ifs="$IFS"
IFS=','
for cidr in $LOCAL_BYPASS_CIDRS; do
  cidr="$(printf '%s' "$cidr" | tr -d ' ')"
  [ -n "$cidr" ] || continue
  "$IPTABLES_BIN" -t mangle -A XRAY -d "$cidr" -j RETURN
done
IFS="$old_ifs"

"$IPTABLES_BIN" -t mangle -A XRAY -p tcp -j TPROXY \
  --on-port "$TPROXY_PORT" --tproxy-mark "$TPROXY_MARK"
"$IPTABLES_BIN" -t mangle -A XRAY -p udp -j TPROXY \
  --on-port "$TPROXY_PORT" --tproxy-mark "$TPROXY_MARK"
"$IPTABLES_BIN" -t mangle -A PREROUTING -i "$INBOUND_INTERFACE" -j XRAY

"$IPTABLES_BIN" -C FORWARD -i "$INBOUND_INTERFACE" -o "$OUTBOUND_INTERFACE" -j ACCEPT 2>/dev/null || \
  "$IPTABLES_BIN" -A FORWARD -i "$INBOUND_INTERFACE" -o "$OUTBOUND_INTERFACE" -j ACCEPT
"$IPTABLES_BIN" -C FORWARD -i "$OUTBOUND_INTERFACE" -o "$INBOUND_INTERFACE" \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  "$IPTABLES_BIN" -A FORWARD -i "$OUTBOUND_INTERFACE" -o "$INBOUND_INTERFACE" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
"$IPTABLES_BIN" -t nat -C POSTROUTING -o "$OUTBOUND_INTERFACE" -j MASQUERADE 2>/dev/null || \
  "$IPTABLES_BIN" -t nat -A POSTROUTING -o "$OUTBOUND_INTERFACE" -j MASQUERADE

escape_yaml_value() {
  printf '%s' "$1" | sed "s/'/''/g"
}

write_socks_config() {
  escaped_user="$(escape_yaml_value "$SOCKS_USER")"
  escaped_password="$(escape_yaml_value "$SOCKS_PASSWORD")"

  umask 077
  {
    printf 'main:\n'
    printf '  workers: %s\n' "$SOCKS_WORKERS"
    printf '  port: %s\n' "$SOCKS_PORT"
    printf "  listen-address: '%s'\n" "$SOCKS_BIND"
    printf "  udp-port: '%s-%s'\n" "$SOCKS_UDP_PORT_MIN" "$SOCKS_UDP_PORT_MAX"
    printf "  udp-listen-address: '%s'\n" "$SOCKS_BIND"
    printf '  listen-ipv6-only: false\n'
    printf '  domain-address-type: ipv4\n'
    if [ -n "$SOCKS_UDP_ADVERTISE_IP" ]; then
      printf "  udp-public-address-v4: '%s'\n" "$SOCKS_UDP_ADVERTISE_IP"
    fi
    if [ -n "$SOCKS_USER" ]; then
      printf 'auth:\n'
      printf "  username: '%s'\n" "$escaped_user"
      printf "  password: '%s'\n" "$escaped_password"
    fi
    printf 'misc:\n'
    printf '  log-file: stderr\n'
    printf '  log-level: warn\n'
  } > /run/xray-socks5-router/hev-socks5-server.yml

  chown socks:socks /run/xray-socks5-router/hev-socks5-server.yml
}

setup_socks_injection() {
  ip link del "$SOCKS_VETH_OUT" 2>/dev/null || true
  ip link del "$SOCKS_VRF" 2>/dev/null || true

  ip link add "$SOCKS_VRF" type vrf table "$SOCKS_VRF_TABLE"
  ip link set "$SOCKS_VRF" up
  ip link add "$SOCKS_VETH_OUT" type veth peer name "$SOCKS_VETH_IN"
  ip link set "$SOCKS_VETH_OUT" master "$SOCKS_VRF"
  ip address add "$SOCKS_VETH_OUT_ADDRESS" dev "$SOCKS_VETH_OUT"
  ip address add "$SOCKS_VETH_IN_ADDRESS" dev "$SOCKS_VETH_IN"
  ip link set "$SOCKS_VETH_OUT" up
  ip link set "$SOCKS_VETH_IN" up

  while ip -4 rule del fwmark "$SOCKS_ROUTE_MARK" table "$SOCKS_ROUTE_TABLE" 2>/dev/null; do :; done
  ip -4 rule add priority "$SOCKS_ROUTE_PRIORITY" fwmark "$SOCKS_ROUTE_MARK" table "$SOCKS_ROUTE_TABLE"
  ip -4 route replace default via "$SOCKS_VETH_GATEWAY" dev "$SOCKS_VETH_OUT" table "$SOCKS_ROUTE_TABLE"

  socks_uid="$(id -u socks)"
  while "$IPTABLES_BIN" -t mangle -D OUTPUT -m owner --uid-owner "$socks_uid" \
    -j HEV_OUTPUT 2>/dev/null; do :; done
  while "$IPTABLES_BIN" -t mangle -D PREROUTING -i "$SOCKS_VETH_IN" \
    -j MARK --set-xmark "$SOCKS_ROUTE_CLEAR_MARK" 2>/dev/null; do :; done
  while "$IPTABLES_BIN" -t mangle -D PREROUTING -i "$SOCKS_VETH_IN" -j XRAY 2>/dev/null; do :; done

  "$IPTABLES_BIN" -t mangle -N HEV_OUTPUT 2>/dev/null || \
    "$IPTABLES_BIN" -t mangle -F HEV_OUTPUT
  "$IPTABLES_BIN" -t mangle -A HEV_OUTPUT -p tcp --sport "$SOCKS_PORT" -j RETURN
  "$IPTABLES_BIN" -t mangle -A HEV_OUTPUT -p udp \
    --sport "${SOCKS_UDP_PORT_MIN}:${SOCKS_UDP_PORT_MAX}" -j RETURN
  "$IPTABLES_BIN" -t mangle -A HEV_OUTPUT -j MARK --set-xmark "$SOCKS_ROUTE_MARK"
  "$IPTABLES_BIN" -t mangle -A OUTPUT -m owner --uid-owner "$socks_uid" -j HEV_OUTPUT
  "$IPTABLES_BIN" -t mangle -A PREROUTING -i "$SOCKS_VETH_IN" \
    -j MARK --set-xmark "$SOCKS_ROUTE_CLEAR_MARK"
  "$IPTABLES_BIN" -t mangle -A PREROUTING -i "$SOCKS_VETH_IN" -j XRAY

  "$IPTABLES_BIN" -C FORWARD -i "$SOCKS_VETH_IN" -o "$INBOUND_INTERFACE" -j ACCEPT 2>/dev/null || \
    "$IPTABLES_BIN" -A FORWARD -i "$SOCKS_VETH_IN" -o "$INBOUND_INTERFACE" -j ACCEPT
}

cleanup() {
  trap - EXIT INT TERM HUP
  [ -z "$SOCKS_PID" ] || kill "$SOCKS_PID" 2>/dev/null || true
  [ -z "$XRAY_PID" ] || kill "$XRAY_PID" 2>/dev/null || true
  [ -z "$SOCKS_PID" ] || wait "$SOCKS_PID" 2>/dev/null || true
  [ -z "$XRAY_PID" ] || wait "$XRAY_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM HUP

/usr/local/bin/xray run -config "$XRAY_CONFIG" &
XRAY_PID="$!"
printf '%s\n' "$XRAY_PID" > /run/xray-socks5-router/xray.pid
sleep 1
kill -0 "$XRAY_PID" 2>/dev/null || fail "Xray stopped during startup"

if [ "$ENABLE_SOCKS" = "1" ]; then
  setup_socks_injection
  if [ -n "$SOCKS_DNS_SERVER" ]; then
    printf 'nameserver %s\n' "$SOCKS_DNS_SERVER" > /etc/resolv.conf
  fi
  write_socks_config
  su-exec socks:socks /usr/local/bin/hev-socks5-server \
    /run/xray-socks5-router/hev-socks5-server.yml &
  SOCKS_PID="$!"
  printf '%s\n' "$SOCKS_PID" > /run/xray-socks5-router/socks.pid
  sleep 1
  kill -0 "$SOCKS_PID" 2>/dev/null || fail "HevSocks5Server stopped during startup"
  log "SOCKS5 ready on ${SOCKS_BIND}:${SOCKS_PORT}; UDP ${SOCKS_UDP_PORT_MIN}-${SOCKS_UDP_PORT_MAX} is injected into Xray"
fi

log "Xray router ready: input=${INBOUND_INTERFACE}, output=${OUTBOUND_INTERFACE}, TPROXY=${TPROXY_PORT}"

while :; do
  if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    wait "$XRAY_PID" || true
    fail "Xray process stopped"
  fi
  if [ "$ENABLE_SOCKS" = "1" ] && ! kill -0 "$SOCKS_PID" 2>/dev/null; then
    wait "$SOCKS_PID" || true
    fail "HevSocks5Server process stopped"
  fi
  sleep 1
done
