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

is_interface_name() {
  [ -n "$1" ] && [ "${#1}" -le 15 ] || return 1
  case "$1" in
    *[!A-Za-z0-9_.-]*) return 1 ;;
    *) return 0 ;;
  esac
}

XRAY_CONFIG="${XRAY_CONFIG:-/etc/xray/config.json}"
ROUTING_MODE="${ROUTING_MODE:-tproxy}"
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

TUN_INTERFACE="${TUN_INTERFACE:-xray0}"
TUN_GATEWAY="${TUN_GATEWAY:-198.18.0.1/30}"
TUN_MTU="${TUN_MTU:-1400}"
TUN_TABLE="${TUN_TABLE:-100}"
TUN_PRIORITY="${TUN_PRIORITY:-1000}"
TUN_SOCKS_PRIORITY="${TUN_SOCKS_PRIORITY:-900}"
TUN_WAIT_SECONDS="${TUN_WAIT_SECONDS:-15}"

ENABLE_SOCKS="${ENABLE_SOCKS:-1}"
SOCKS_BIND="${SOCKS_BIND:-0.0.0.0}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASSWORD="${SOCKS_PASSWORD:-}"
SOCKS_ALLOW_NO_AUTH="${SOCKS_ALLOW_NO_AUTH:-0}"
SOCKS_DNS_SERVER="${SOCKS_DNS_SERVER:-1.1.1.1}"
SOCKS_WORKERS="${SOCKS_WORKERS:-2}"
SOCKS_LOG_LEVEL="${SOCKS_LOG_LEVEL:-warn}"
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

case "$ROUTING_MODE" in
  tproxy)
    command -v "$IPTABLES_BIN" >/dev/null 2>&1 || \
      fail "iptables backend not found: $IPTABLES_BIN"
    ;;
  tun)
    [ -c /dev/net/tun ] || \
      fail "ROUTING_MODE=tun requires /dev/net/tun inside the container"
    ;;
  *) fail "ROUTING_MODE must be tproxy or tun" ;;
esac

is_uint "$TPROXY_PORT" || fail "TPROXY_PORT must be numeric"
is_uint "$TPROXY_TABLE" || fail "TPROXY_TABLE must be numeric"
is_uint "$TPROXY_PRIORITY" || fail "TPROXY_PRIORITY must be numeric"
is_uint "$TUN_TABLE" || fail "TUN_TABLE must be numeric"
is_uint "$TUN_MTU" || fail "TUN_MTU must be numeric"
is_uint "$TUN_PRIORITY" || fail "TUN_PRIORITY must be numeric"
is_uint "$TUN_SOCKS_PRIORITY" || fail "TUN_SOCKS_PRIORITY must be numeric"
is_uint "$TUN_WAIT_SECONDS" || fail "TUN_WAIT_SECONDS must be numeric"

if [ "$TUN_TABLE" -le 0 ] || [ "$TUN_TABLE" -ge 253 ]; then
  fail "TUN_TABLE must be between 1 and 252"
fi
if [ "$TUN_MTU" -lt 576 ] || [ "$TUN_MTU" -gt 65535 ]; then
  fail "TUN_MTU must be between 576 and 65535"
fi
[ "$TUN_PRIORITY" -gt 200 ] || \
  fail "TUN_PRIORITY must be greater than 200 for RouterOS compatibility"
[ "$TUN_SOCKS_PRIORITY" -gt 200 ] || \
  fail "TUN_SOCKS_PRIORITY must be greater than 200 for RouterOS compatibility"
[ "$TUN_WAIT_SECONDS" -gt 0 ] || fail "TUN_WAIT_SECONDS must be positive"

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

  if [ "$ROUTING_MODE" = "tun" ]; then
    [ "$SOCKS_ROUTE_TABLE" != "$TUN_TABLE" ] || \
      fail "SOCKS_ROUTE_TABLE must differ from TUN_TABLE in TUN mode"
    [ "$TUN_SOCKS_PRIORITY" != "$TUN_PRIORITY" ] || \
      fail "TUN_SOCKS_PRIORITY must differ from TUN_PRIORITY"
  fi

  if [ "$SOCKS_PORT" -lt 1024 ] || [ "$SOCKS_PORT" -gt 65535 ]; then
    fail "invalid SOCKS_PORT"
  fi
  if [ "$SOCKS_UDP_PORT_MIN" -lt 1024 ] || \
    [ "$SOCKS_UDP_PORT_MAX" -gt 65535 ] || \
    [ "$SOCKS_UDP_PORT_MIN" -gt "$SOCKS_UDP_PORT_MAX" ]; then
    fail "invalid SOCKS UDP range"
  fi

  if [ -n "$SOCKS_USER" ] || [ -n "$SOCKS_PASSWORD" ]; then
    if [ -z "$SOCKS_USER" ] || [ -z "$SOCKS_PASSWORD" ]; then
      fail "SOCKS_USER and SOCKS_PASSWORD must be set together"
    fi
  else
    [ "$SOCKS_ALLOW_NO_AUTH" = "1" ] || \
      fail "set SOCKS credentials or explicitly set SOCKS_ALLOW_NO_AUTH=1"
  fi

  if printf '%s%s' "$SOCKS_USER" "$SOCKS_PASSWORD" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "SOCKS credentials must not contain control characters"
  fi
  if [ "${#SOCKS_USER}" -gt 255 ] || [ "${#SOCKS_PASSWORD}" -gt 255 ]; then
    fail "SOCKS credentials must not exceed 255 characters"
  fi
  case "$SOCKS_LOG_LEVEL" in
    debug|info|warn|error) ;;
    *) fail "SOCKS_LOG_LEVEL must be debug, info, warn, or error" ;;
  esac
fi

/usr/local/bin/xray run -test -config "$XRAY_CONFIG"

prepare_xray_config() {
  [ "$ROUTING_MODE" = "tun" ] || return 0

  if jq -e 'any(.inbounds[]?; .protocol == "tun")' "$XRAY_CONFIG" >/dev/null; then
    return 0
  fi

  compatible_inbounds="$(jq '[.inbounds[]? | select(
    .protocol == "dokodemo-door" and
    .streamSettings.sockopt.tproxy == "tproxy"
  )] | length' "$XRAY_CONFIG")"
  [ "$compatible_inbounds" -gt 0 ] || \
    fail "ROUTING_MODE=tun requires a TUN or TPROXY dokodemo-door inbound"

  effective_config=/run/xray-socks5-router/xray-effective.json
  jq \
    --arg name "$TUN_INTERFACE" \
    --arg gateway "$TUN_GATEWAY" \
    --argjson mtu "$TUN_MTU" \
    '.inbounds |= map(
      if .protocol == "dokodemo-door" and
         .streamSettings.sockopt.tproxy == "tproxy"
      then
        del(.listen, .port, .streamSettings) |
        .protocol = "tun" |
        .settings = {name: $name, mtu: $mtu, gateway: [$gateway]}
      else . end
    )' \
    "$XRAY_CONFIG" > "$effective_config"
  chmod 0600 "$effective_config"
  XRAY_CONFIG="$effective_config"
  log "Converted the mounted TPROXY inbound to an ephemeral TUN config"
}

prepare_xray_config
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
is_interface_name "$INBOUND_INTERFACE" || \
  fail "INBOUND_INTERFACE contains unsupported characters"
is_interface_name "$OUTBOUND_INTERFACE" || \
  fail "OUTBOUND_INTERFACE contains unsupported characters"
is_interface_name "$TUN_INTERFACE" || \
  fail "TUN_INTERFACE contains unsupported characters"
ip link set dev "$INBOUND_INTERFACE" up
ip link set dev "$OUTBOUND_INTERFACE" up

umask 077
{
  printf 'ROUTING_MODE=%s\n' "$ROUTING_MODE"
  printf 'INBOUND_INTERFACE=%s\n' "$INBOUND_INTERFACE"
  printf 'TUN_INTERFACE=%s\n' "$TUN_INTERFACE"
  printf 'TUN_TABLE=%s\n' "$TUN_TABLE"
  printf 'TUN_PRIORITY=%s\n' "$TUN_PRIORITY"
  printf 'TUN_SOCKS_PRIORITY=%s\n' "$TUN_SOCKS_PRIORITY"
} > /run/xray-socks5-router/runtime.env

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

if [ "$ROUTING_MODE" = "tproxy" ]; then
  while ip -4 rule del priority "$TUN_PRIORITY" 2>/dev/null; do :; done
  while ip -4 rule del priority "$TUN_SOCKS_PRIORITY" 2>/dev/null; do :; done
  ip -4 route flush table "$TUN_TABLE" >/dev/null 2>&1 || true
  if [ "$SOCKS_ROUTE_TABLE" != "$TUN_TABLE" ]; then
    ip -4 route flush table "$SOCKS_ROUTE_TABLE" >/dev/null 2>&1 || true
  fi
else
  while ip -4 rule del fwmark "$TPROXY_MARK" table "$TPROXY_TABLE" 2>/dev/null; do :; done
  ip -4 route flush table "$TPROXY_TABLE" >/dev/null 2>&1 || true
  ip link del "$SOCKS_VETH_OUT" >/dev/null 2>&1 || true
  ip link del "$SOCKS_VRF" >/dev/null 2>&1 || true

  if command -v "$IPTABLES_BIN" >/dev/null 2>&1; then
    socks_uid="$(id -u socks)"
    while "$IPTABLES_BIN" -t mangle -D PREROUTING \
      -i "$INBOUND_INTERFACE" -j XRAY >/dev/null 2>&1; do :; done
    while "$IPTABLES_BIN" -t mangle -D OUTPUT -m owner \
      --uid-owner "$socks_uid" -j HEV_OUTPUT >/dev/null 2>&1; do :; done
    while "$IPTABLES_BIN" -t mangle -D PREROUTING \
      -i "$SOCKS_VETH_IN" -j MARK \
      --set-xmark "$SOCKS_ROUTE_CLEAR_MARK" >/dev/null 2>&1; do :; done
    while "$IPTABLES_BIN" -t mangle -D PREROUTING \
      -i "$SOCKS_VETH_IN" -j XRAY >/dev/null 2>&1; do :; done
    while "$IPTABLES_BIN" -D FORWARD -i "$SOCKS_VETH_IN" \
      -o "$INBOUND_INTERFACE" -j ACCEPT >/dev/null 2>&1; do :; done
    "$IPTABLES_BIN" -t mangle -F HEV_OUTPUT >/dev/null 2>&1 || true
    "$IPTABLES_BIN" -t mangle -X HEV_OUTPUT >/dev/null 2>&1 || true
    "$IPTABLES_BIN" -t mangle -F XRAY >/dev/null 2>&1 || true
    "$IPTABLES_BIN" -t mangle -X XRAY >/dev/null 2>&1 || true
    "$IPTABLES_BIN" -t nat -D POSTROUTING -o "$OUTBOUND_INTERFACE" \
      -j MASQUERADE >/dev/null 2>&1 || true
  fi
fi

if [ "$ROUTING_MODE" = "tproxy" ]; then
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
fi

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
    printf '  log-level: %s\n' "$SOCKS_LOG_LEVEL"
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

add_cidrs_to_table() {
  cidrs="$1"
  gateway="$2"
  interface="$3"
  table="$4"

  [ -n "$cidrs" ] || return 0
  ip -4 route replace table "$table" "${gateway}/32" dev "$interface" scope link

  old_ifs="$IFS"
  IFS=','
  for cidr in $cidrs; do
    cidr="$(printf '%s' "$cidr" | tr -d ' ')"
    [ -n "$cidr" ] || continue
    ip -4 route replace table "$table" "$cidr" via "$gateway" dev "$interface"
  done
  IFS="$old_ifs"
}

setup_tun_route_table() {
  table="$1"

  ip -4 route flush table "$table" >/dev/null 2>&1 || true
  ip -4 route show dev "$INBOUND_INTERFACE" scope link | \
    while IFS= read -r route; do
      [ -n "$route" ] || continue
      # Intentionally split the route returned by iproute2.
      # shellcheck disable=SC2086
      set -- $route
      ip -4 route replace table "$table" "$1" \
        dev "$INBOUND_INTERFACE" scope link
    done
  add_cidrs_to_table \
    "$LOCAL_BYPASS_CIDRS" "$OUTBOUND_GATEWAY" "$OUTBOUND_INTERFACE" "$table"
  if [ -n "$return_cidrs_compact" ]; then
    add_cidrs_to_table \
      "$RETURN_CIDRS" "$INBOUND_GATEWAY" "$INBOUND_INTERFACE" "$table"
  fi
  ip -4 route replace table "$table" default dev "$TUN_INTERFACE"
}

wait_for_tun_interface() {
  elapsed=0
  while ! ip link show dev "$TUN_INTERFACE" >/dev/null 2>&1; do
    kill -0 "$XRAY_PID" 2>/dev/null || fail "Xray stopped before creating $TUN_INTERFACE"
    [ "$elapsed" -lt "$TUN_WAIT_SECONDS" ] || \
      fail "Xray did not create TUN interface $TUN_INTERFACE within ${TUN_WAIT_SECONDS}s"
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

setup_tun_routing() {
  [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || \
    fail "TUN mode requires net.ipv4.ip_forward=1"
  [ "$(cat /proc/sys/net/ipv4/conf/all/rp_filter)" = "0" ] || \
    fail "TUN mode requires net.ipv4.conf.all.rp_filter=0"

  wait_for_tun_interface
  ip link set dev "$TUN_INTERFACE" up
  setup_tun_route_table "$TUN_TABLE"
  while ip -4 rule del priority "$TUN_PRIORITY" 2>/dev/null; do :; done
  ip -4 rule add priority "$TUN_PRIORITY" \
    iif "$INBOUND_INTERFACE" table "$TUN_TABLE"
}

setup_tun_socks_injection() {
  socks_uid="$(id -u socks)"
  setup_tun_route_table "$SOCKS_ROUTE_TABLE"
  while ip -4 rule del priority "$TUN_SOCKS_PRIORITY" 2>/dev/null; do :; done
  ip -4 rule add priority "$TUN_SOCKS_PRIORITY" \
    uidrange "${socks_uid}-${socks_uid}" table "$SOCKS_ROUTE_TABLE"
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

if [ "$ROUTING_MODE" = "tun" ]; then
  setup_tun_routing
fi

if [ "$ENABLE_SOCKS" = "1" ]; then
  if [ "$ROUTING_MODE" = "tun" ]; then
    setup_tun_socks_injection
  else
    setup_socks_injection
  fi
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

if [ "$ROUTING_MODE" = "tun" ]; then
  log "Xray router ready: mode=tun, input=${INBOUND_INTERFACE}, output=${OUTBOUND_INTERFACE}, tun=${TUN_INTERFACE}"
else
  log "Xray router ready: mode=tproxy, input=${INBOUND_INTERFACE}, output=${OUTBOUND_INTERFACE}, TPROXY=${TPROXY_PORT}"
fi

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
