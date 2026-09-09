#!/usr/bin/env python3
"""Generate an Xray L3-gateway configuration from a VLESS share URI."""

from __future__ import annotations

import argparse
import base64
import binascii
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import parse_qsl, unquote, urlsplit
import uuid


DEFAULT_OUTPUT = "examples/config/config.json"
TRANSPORTS = {
    "tcp": "raw",
    "raw": "raw",
    "ws": "websocket",
    "websocket": "websocket",
    "grpc": "grpc",
    "httpupgrade": "httpupgrade",
    "xhttp": "xhttp",
    "kcp": "mkcp",
}
KNOWN_PARAMETERS = {
    "alpn",
    "allowInsecure",
    "authority",
    "ech",
    "encryption",
    "extra",
    "flow",
    "fm",
    "fp",
    "headerType",
    "host",
    "mode",
    "mtu",
    "packetEncoding",
    "path",
    "pbk",
    "pcs",
    "pqv",
    "security",
    "seed",
    "serviceName",
    "sid",
    "sni",
    "spx",
    "tti",
    "type",
    "vcn",
}
COMMON_PARAMETERS = {
    "allowInsecure",
    "encryption",
    "flow",
    "fm",
    "packetEncoding",
    "security",
    "type",
}
TRANSPORT_PARAMETERS = {
    "raw": {"headerType"},
    "websocket": {"host", "path"},
    "grpc": {"authority", "mode", "serviceName"},
    "httpupgrade": {"host", "path"},
    "xhttp": {"extra", "host", "mode", "path"},
    "mkcp": {"headerType", "mtu", "seed", "tti"},
}
SECURITY_PARAMETERS = {
    "none": set(),
    "tls": {"alpn", "ech", "fp", "pcs", "sni", "vcn"},
    "reality": {"fp", "pbk", "pqv", "sid", "sni", "spx"},
}


class ConfigError(ValueError):
    """A safe, user-facing validation error that never contains the URI."""


def _parse_tun_mtu(value: str | int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise ConfigError("TUN MTU must be an integer") from exc
    if not 576 <= parsed <= 65535:
        raise ConfigError("TUN MTU must be between 576 and 65535")
    return parsed


def _parse_tun_gateway(value: str) -> str:
    try:
        gateway = ipaddress.ip_interface(value)
    except ValueError as exc:
        raise ConfigError("TUN gateway must be a valid IPv4 interface prefix") from exc
    if gateway.version != 4:
        raise ConfigError("TUN gateway must be an IPv4 interface prefix")
    return str(gateway)


def _validate_tun_interface(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", value):
        raise ConfigError(
            "TUN interface must be 1-15 letters, digits, dots, underscores, or hyphens"
        )
    return value


def _parse_port(value: str, field: str) -> int:
    try:
        parsed = int(value, 10)
    except ValueError as exc:
        raise ConfigError(f"{field} must be an integer") from exc
    if not 1 <= parsed <= 65535:
        raise ConfigError(f"{field} must be between 1 and 65535")
    return parsed


def _parse_optional_int(query: dict[str, str], field: str) -> int | None:
    if field not in query:
        return None
    try:
        parsed = int(query[field], 10)
    except ValueError as exc:
        raise ConfigError(f"query parameter {field!r} must be an integer") from exc
    if parsed <= 0:
        raise ConfigError(f"query parameter {field!r} must be positive")
    return parsed


def _parse_json_object(value: str, field: str) -> dict[str, object]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise ConfigError(f"query parameter {field!r} must contain valid JSON") from exc
    if not isinstance(parsed, dict):
        raise ConfigError(f"query parameter {field!r} must contain a JSON object")
    return parsed


def _parse_query(query_string: str) -> dict[str, str]:
    try:
        pairs = parse_qsl(
            query_string,
            keep_blank_values=True,
            strict_parsing=False,
            max_num_fields=100,
        )
    except ValueError as exc:
        raise ConfigError("the URI query string is invalid") from exc

    query: dict[str, str] = {}
    for key, value in pairs:
        if not key:
            raise ConfigError("the URI contains an empty query parameter name")
        if key in query:
            raise ConfigError(f"query parameter {key!r} occurs more than once")
        query[key] = value

    unknown = sorted(set(query) - KNOWN_PARAMETERS)
    if unknown:
        names = ", ".join(repr(name) for name in unknown)
        raise ConfigError(f"unsupported query parameter(s): {names}")
    return query


def _normalise_host(host: str) -> str:
    try:
        ipaddress.ip_address(host)
        return host
    except ValueError:
        pass

    try:
        ascii_host = host.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise ConfigError("the server host name is invalid") from exc
    if not ascii_host or len(ascii_host) > 253:
        raise ConfigError("the server host name is invalid")
    return ascii_host


def _validate_uuid(value: str) -> str:
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as exc:
        raise ConfigError("the VLESS user ID must be a UUID") from exc
    canonical = str(parsed)
    if value.lower() != canonical:
        raise ConfigError("the VLESS user ID must use canonical UUID syntax")
    return canonical


def _validate_reality_password(value: str) -> str:
    if "=" in value:
        raise ConfigError("REALITY 'pbk' must use unpadded base64url syntax")
    padding = "=" * (-len(value) % 4)
    try:
        decoded = base64.b64decode(value + padding, altchars=b"-_", validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ConfigError("REALITY 'pbk' is not valid base64url") from exc
    if len(decoded) != 32:
        raise ConfigError("REALITY 'pbk' must encode exactly 32 bytes")
    return value


def _validate_parameter_context(
    query: dict[str, str], method: str, security: str
) -> None:
    allowed = (
        COMMON_PARAMETERS | TRANSPORT_PARAMETERS[method] | SECURITY_PARAMETERS[security]
    )

    # Several clients emit headerType=none for every transport. It carries no
    # configuration outside RAW/mKCP, but accepting the no-op value is harmless.
    if query.get("headerType") in {"", "none"}:
        allowed.add("headerType")

    invalid = sorted(set(query) - allowed)
    if invalid:
        names = ", ".join(repr(name) for name in invalid)
        raise ConfigError(
            f"query parameter(s) not valid for {method}/{security}: {names}"
        )


def _configure_transport(
    stream: dict[str, object], query: dict[str, str], uri_type: str
) -> str:
    if uri_type == "http":
        raise ConfigError(
            "legacy type='http' is ambiguous; convert the share URI to xhttp first"
        )
    try:
        method = TRANSPORTS[uri_type]
    except KeyError as exc:
        raise ConfigError(f"unsupported VLESS transport type {uri_type!r}") from exc

    stream["method"] = method

    if method == "raw":
        header_type = query.get("headerType", "none")
        if header_type not in {"", "none"}:
            raise ConfigError("RAW headerType values other than 'none' are unsupported")
    elif method == "websocket":
        settings: dict[str, object] = {"path": query.get("path", "/")}
        if query.get("host"):
            settings["host"] = query["host"]
        stream["wsSettings"] = settings
    elif method == "grpc":
        service_name = query.get("serviceName")
        if service_name == "":
            raise ConfigError("gRPC serviceName cannot be empty")
        settings = {}
        if service_name is not None:
            settings["serviceName"] = service_name
        if "authority" in query:
            settings["authority"] = query["authority"]
        mode = query.get("mode", "gun")
        if mode == "multi":
            settings["multiMode"] = True
        elif mode == "guna":
            raise ConfigError("gRPC mode='guna' is not supported by this generator")
        elif mode != "gun":
            raise ConfigError("gRPC mode must be 'gun' or 'multi'")
        stream["grpcSettings"] = settings
    elif method == "httpupgrade":
        settings = {"path": query.get("path", "/")}
        if query.get("host"):
            settings["host"] = query["host"]
        stream["httpupgradeSettings"] = settings
    elif method == "xhttp":
        settings = {"path": query.get("path", "/")}
        if query.get("host"):
            settings["host"] = query["host"]
        if query.get("mode"):
            settings["mode"] = query["mode"]
        if "extra" in query:
            settings["extra"] = _parse_json_object(query["extra"], "extra")
        stream["xhttpSettings"] = settings
    elif method == "mkcp":
        settings = {}
        for field in ("mtu", "tti"):
            value = _parse_optional_int(query, field)
            if value is not None:
                settings[field] = value
        if query.get("seed"):
            raise ConfigError(
                "mKCP 'seed' was removed by current Xray; use the share URI 'fm' "
                "finalmask parameter"
            )
        header_type = query.get("headerType")
        if header_type not in {None, "", "none"}:
            raise ConfigError(
                "mKCP 'headerType' was removed by current Xray; use the share URI "
                "'fm' finalmask parameter"
            )
        stream["kcpSettings"] = settings

    return method


def _configure_security(
    stream: dict[str, object], query: dict[str, str], method: str, host: str
) -> str:
    security = query.get("security", "none")
    if not security:
        raise ConfigError("query parameter 'security' cannot be empty")
    if security not in {"none", "tls", "reality"}:
        raise ConfigError(f"unsupported transport security {security!r}")
    stream["security"] = security

    allow_insecure = query.get("allowInsecure")
    if allow_insecure is not None and allow_insecure.lower() not in {"", "0", "false"}:
        raise ConfigError(
            "allowInsecure is unsafe and no longer supported by current Xray"
        )

    if security == "reality":
        if method not in {"raw", "xhttp", "grpc"}:
            raise ConfigError("REALITY supports only RAW, XHTTP, and gRPC transports")
        password = query.get("pbk")
        if not password:
            raise ConfigError("REALITY requires a non-empty 'pbk' parameter")
        password = _validate_reality_password(password)
        fingerprint = query.get("fp")
        if not fingerprint:
            raise ConfigError("REALITY requires a non-empty 'fp' parameter")
        settings: dict[str, object] = {
            "serverName": query.get("sni") or host,
            "fingerprint": fingerprint,
            "password": password,
        }
        for uri_key, config_key in (
            ("sid", "shortId"),
            ("pqv", "mldsa65Verify"),
            ("spx", "spiderX"),
        ):
            if uri_key in query:
                settings[config_key] = query[uri_key]
        stream["realitySettings"] = settings
    elif security == "tls":
        settings = {"serverName": query.get("sni") or host}
        if query.get("fp"):
            settings["fingerprint"] = query["fp"]
        if query.get("alpn"):
            settings["alpn"] = query["alpn"].split(",")
        for uri_key, config_key in (
            ("ech", "echConfigList"),
            ("pcs", "pinnedPeerCertSha256"),
            ("vcn", "verifyPeerCertByName"),
        ):
            if uri_key in query:
                settings[config_key] = query[uri_key]
        stream["tlsSettings"] = settings

    if "fm" in query:
        stream["finalmask"] = _parse_json_object(query["fm"], "fm")

    return security


def build_config(
    uri: str,
    tproxy_port: int = 12345,
    log_level: str = "warning",
    routing_mode: str = "tproxy",
    tun_interface: str = "xray0",
    tun_mtu: int = 1400,
    tun_gateway: str = "198.18.0.1/30",
) -> dict:
    """Convert one VLESS share URI to a complete gateway config."""
    if not uri or any(char in uri for char in "\r\n"):
        raise ConfigError("input must contain exactly one VLESS URI")

    try:
        parsed = urlsplit(uri)
    except ValueError as exc:
        raise ConfigError("the VLESS URI is malformed") from exc
    if parsed.scheme != "vless":
        raise ConfigError("the URI scheme must be exactly 'vless'")
    if parsed.password is not None:
        raise ConfigError("a VLESS URI must not contain a password in userinfo")
    if parsed.username is None:
        raise ConfigError("the VLESS URI does not contain a user ID")
    user_id = _validate_uuid(unquote(parsed.username))

    try:
        parsed_host = parsed.hostname
        parsed_port = parsed.port
    except ValueError as exc:
        raise ConfigError("the server host or port is invalid") from exc
    if not parsed_host:
        raise ConfigError("the VLESS URI does not contain a server host")
    if parsed_port is None:
        raise ConfigError("the VLESS URI does not contain a server port")
    host = _normalise_host(parsed_host)
    port = _parse_port(str(parsed_port), "server port")

    query = _parse_query(parsed.query)
    encryption = query.get("encryption", "none")
    if not encryption:
        raise ConfigError("query parameter 'encryption' cannot be empty")

    user: dict[str, object] = {"id": user_id, "encryption": encryption}
    if query.get("flow"):
        user["flow"] = query["flow"]

    outbound_settings: dict[str, object] = {
        "vnext": [{"address": host, "port": port, "users": [user]}]
    }
    packet_encoding = query.get("packetEncoding")
    if packet_encoding and packet_encoding != "none":
        if packet_encoding not in {"packet", "xudp"}:
            raise ConfigError("packetEncoding must be 'packet', 'xudp', or 'none'")
        outbound_settings["packetEncoding"] = packet_encoding

    stream: dict[str, object] = {}
    uri_type = query.get("type", "tcp")
    if not uri_type:
        raise ConfigError("query parameter 'type' cannot be empty")
    method = _configure_transport(stream, query, uri_type)
    security = _configure_security(stream, query, method, host)
    _validate_parameter_context(query, method, security)

    if routing_mode == "tproxy":
        inbound_tag = "tproxy-in"
        inbound = {
            "tag": inbound_tag,
            "listen": "0.0.0.0",
            "port": tproxy_port,
            "protocol": "dokodemo-door",
            "settings": {"network": "tcp,udp", "followRedirect": True},
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": True,
            },
            "streamSettings": {"sockopt": {"tproxy": "tproxy"}},
        }
    elif routing_mode == "tun":
        inbound_tag = "tun-in"
        inbound = {
            "tag": inbound_tag,
            "protocol": "tun",
            "settings": {
                "name": _validate_tun_interface(tun_interface),
                "mtu": _parse_tun_mtu(tun_mtu),
                "gateway": [_parse_tun_gateway(tun_gateway)],
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": True,
            },
        }
    else:
        raise ConfigError("routing mode must be 'tproxy' or 'tun'")

    return {
        "log": {"loglevel": log_level},
        "inbounds": [inbound],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": outbound_settings,
                "streamSettings": stream,
            }
        ],
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {
                    "type": "field",
                    "inboundTag": [inbound_tag],
                    "outboundTag": "proxy",
                }
            ],
        },
    }


def _read_uri(args: argparse.Namespace) -> str:
    if args.uri is not None:
        print(
            "warning: --uri may store credentials in shell history; "
            "prefer --uri-file or --stdin",
            file=sys.stderr,
        )
        return args.uri.strip()

    if args.uri_file is not None:
        try:
            text = Path(args.uri_file).read_text(encoding="utf-8-sig")
        except OSError as exc:
            raise ConfigError(f"cannot read URI file: {exc.strerror or exc}") from exc
    else:
        text = sys.stdin.read()

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        raise ConfigError("input must contain exactly one non-empty line")
    return lines[0]


def _write_config(config: dict, output: str, force: bool) -> None:
    rendered = json.dumps(config, indent=2, ensure_ascii=False) + "\n"
    if output == "-":
        sys.stdout.write(rendered)
        return

    destination = Path(output)
    if destination.exists() and not force:
        raise ConfigError(f"output file already exists: {destination}; use --force")
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(
            prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(rendered)
            try:
                os.chmod(temporary, 0o600)
            except OSError:
                pass
            os.replace(temporary, destination)
        except BaseException:
            try:
                os.unlink(temporary)
            except OSError:
                pass
            raise
    except OSError as exc:
        raise ConfigError(f"cannot write output file: {exc.strerror or exc}") from exc


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate an Xray L3-gateway config from one VLESS share URI."
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--uri-file", metavar="PATH", help="read the URI from a file")
    source.add_argument("--stdin", action="store_true", help="read the URI from stdin")
    source.add_argument("--uri", help="read the URI from an argument (less private)")
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        metavar="PATH",
        help=f"output file, or '-' for stdout (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--force", action="store_true", help="overwrite an existing file"
    )
    parser.add_argument(
        "--tproxy-port",
        type=lambda value: _parse_port(value, "TPROXY port"),
        default=12345,
        metavar="PORT",
    )
    parser.add_argument(
        "--routing-mode",
        choices=("tproxy", "tun"),
        default="tproxy",
        help="gateway interception mode (default: tproxy)",
    )
    parser.add_argument(
        "--tun-interface",
        type=_validate_tun_interface,
        default="xray0",
        metavar="NAME",
        help="TUN interface name for --routing-mode tun (default: xray0)",
    )
    parser.add_argument(
        "--tun-mtu",
        type=_parse_tun_mtu,
        default=1400,
        metavar="MTU",
        help="TUN MTU for --routing-mode tun (default: 1400)",
    )
    parser.add_argument(
        "--tun-gateway",
        type=_parse_tun_gateway,
        default="198.18.0.1/30",
        metavar="PREFIX",
        help="IPv4 address/prefix assigned to TUN (default: 198.18.0.1/30)",
    )
    parser.add_argument("--log-level", default="warning", metavar="LEVEL")
    return parser


def main() -> int:
    parser = _argument_parser()
    args = parser.parse_args()
    try:
        uri = _read_uri(args)
        config = build_config(
            uri,
            args.tproxy_port,
            args.log_level,
            args.routing_mode,
            args.tun_interface,
            args.tun_mtu,
            args.tun_gateway,
        )
        _write_config(config, args.output, args.force)
    except ConfigError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.output != "-":
        print(f"Wrote Xray configuration to {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
