#!/usr/bin/env python3
import ipaddress
import socket
import struct
import sys


def recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError("SOCKS control connection closed unexpectedly")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_address(sock: socket.socket, atyp: int) -> str:
    if atyp == 1:
        return str(ipaddress.ip_address(recv_exact(sock, 4)))
    if atyp == 4:
        return str(ipaddress.ip_address(recv_exact(sock, 16)))
    if atyp == 3:
        length = recv_exact(sock, 1)[0]
        return recv_exact(sock, length).decode("ascii")
    raise RuntimeError(f"unsupported address type: {atyp}")


def main() -> int:
    proxy_host = "127.0.0.1"
    proxy_port = 11080
    target_ip = "198.51.100.20"
    target_port = 9999
    payload = b"xray-socks5-router-udp-smoke"

    with socket.create_connection((proxy_host, proxy_port), timeout=10) as control:
        control.settimeout(10)
        control.sendall(b"\x05\x01\x00")
        if recv_exact(control, 2) != b"\x05\x00":
            raise RuntimeError("SOCKS server did not accept no-auth mode")

        request = b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00"
        control.sendall(request)
        version, reply, reserved, atyp = recv_exact(control, 4)
        if (version, reply, reserved) != (5, 0, 0):
            raise RuntimeError(f"UDP ASSOCIATE failed with reply {reply}")

        relay_host = read_address(control, atyp)
        relay_port = struct.unpack("!H", recv_exact(control, 2))[0]
        if relay_host in ("0.0.0.0", "::"):
            relay_host = proxy_host

        packet = (
            b"\x00\x00\x00\x01"
            + socket.inet_aton(target_ip)
            + struct.pack("!H", target_port)
            + payload
        )

        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.settimeout(10)
            udp.sendto(packet, (relay_host, relay_port))
            response, _ = udp.recvfrom(65535)

        if len(response) < 10 or response[:3] != b"\x00\x00\x00":
            raise RuntimeError("invalid SOCKS5 UDP response")

        response_atyp = response[3]
        if response_atyp == 1:
            payload_offset = 10
        elif response_atyp == 4:
            payload_offset = 22
        elif response_atyp == 3:
            payload_offset = 7 + response[4]
        else:
            raise RuntimeError(f"invalid response address type: {response_atyp}")

        if response[payload_offset:] != payload:
            raise RuntimeError("UDP echo payload mismatch")

    print("SOCKS5 UDP ASSOCIATE smoke test passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 - command-line smoke test
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
