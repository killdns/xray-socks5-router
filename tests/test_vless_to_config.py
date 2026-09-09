#!/usr/bin/env python3

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).parents[1] / "tools" / "vless_to_config.py"
SPEC = importlib.util.spec_from_file_location("vless_to_config", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
REALITY_PASSWORD = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"


class BuildConfigTests(unittest.TestCase):
    def test_reality_raw_uses_current_xray_fields(self):
        config = MODULE.build_config(
            "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@203.0.113.10:443"
            "?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision"
            f"&sni=example.com&fp=chrome&pbk={REALITY_PASSWORD}&sid=0123456789abcdef"
            "&spx=%2Fdocs%3Fa%3D1&headerType=none&packetEncoding=xudp#example"
        )

        outbound = config["outbounds"][0]
        self.assertEqual(outbound["streamSettings"]["method"], "raw")
        self.assertEqual(
            outbound["streamSettings"]["realitySettings"],
            {
                "serverName": "example.com",
                "fingerprint": "chrome",
                "password": REALITY_PASSWORD,
                "shortId": "0123456789abcdef",
                "spiderX": "/docs?a=1",
            },
        )
        self.assertEqual(outbound["settings"]["packetEncoding"], "xudp")
        self.assertEqual(config["inbounds"][0]["port"], 12345)

    def test_tls_websocket(self):
        config = MODULE.build_config(
            "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:8443"
            "?type=ws&security=tls&path=%2Fproxy&host=edge.example.com"
            "&sni=tls.example.com&fp=chrome&alpn=h2%2Chttp%2F1.1"
        )
        stream = config["outbounds"][0]["streamSettings"]
        self.assertEqual(stream["method"], "websocket")
        self.assertEqual(
            stream["wsSettings"],
            {"path": "/proxy", "host": "edge.example.com"},
        )
        self.assertEqual(stream["tlsSettings"]["alpn"], ["h2", "http/1.1"])

    def test_reality_grpc_multi(self):
        config = MODULE.build_config(
            "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:443"
            "?type=grpc&security=reality&serviceName=proxy&mode=multi"
            f"&authority=edge.example.com&fp=firefox&pbk={REALITY_PASSWORD}"
        )
        stream = config["outbounds"][0]["streamSettings"]
        self.assertEqual(stream["method"], "grpc")
        self.assertEqual(
            stream["grpcSettings"],
            {
                "serviceName": "proxy",
                "authority": "edge.example.com",
                "multiMode": True,
            },
        )

    def test_duplicate_query_parameter_is_rejected(self):
        with self.assertRaisesRegex(MODULE.ConfigError, "more than once"):
            MODULE.build_config(
                "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:443"
                "?security=none&security=tls"
            )

    def test_unknown_query_parameter_is_rejected(self):
        with self.assertRaisesRegex(MODULE.ConfigError, "unsupported query"):
            MODULE.build_config(
                "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:443"
                "?mystery=value"
            )

    def test_invalid_uuid_and_port_are_rejected(self):
        with self.assertRaisesRegex(MODULE.ConfigError, "must be a UUID"):
            MODULE.build_config("vless://not-a-uuid@example.com:443")
        with self.assertRaisesRegex(MODULE.ConfigError, "port"):
            MODULE.build_config(
                "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:70000"
            )

    def test_reality_transport_compatibility_is_enforced(self):
        with self.assertRaisesRegex(MODULE.ConfigError, "supports only"):
            MODULE.build_config(
                "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:443"
                f"?type=ws&security=reality&fp=chrome&pbk={REALITY_PASSWORD}"
            )

    def test_invalid_reality_password_is_rejected(self):
        with self.assertRaisesRegex(MODULE.ConfigError, "pbk"):
            MODULE.build_config(
                "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:443"
                "?type=tcp&security=reality&fp=chrome&pbk=not-a-key"
            )

    def test_transport_specific_parameter_is_not_silently_ignored(self):
        with self.assertRaisesRegex(MODULE.ConfigError, "not valid"):
            MODULE.build_config(
                "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:443"
                "?type=tcp&serviceName=wrong-transport"
            )

    def test_mkcp_current_fields(self):
        config = MODULE.build_config(
            "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@203.0.113.20:12345"
            "?type=kcp&security=none&headerType=none&mtu=1350&tti=50"
        )
        stream = config["outbounds"][0]["streamSettings"]
        self.assertEqual(stream["method"], "mkcp")
        self.assertEqual(stream["kcpSettings"], {"mtu": 1350, "tti": 50})

    def test_mkcp_removed_seed_is_rejected(self):
        with self.assertRaisesRegex(MODULE.ConfigError, "was removed"):
            MODULE.build_config(
                "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@203.0.113.20:12345"
                "?type=kcp&seed=legacy"
            )


class OutputTests(unittest.TestCase):
    def test_existing_output_requires_force(self):
        config = MODULE.build_config(
            "vless://b0dd64e4-0fbd-4038-9139-d1f32a68a0dc@example.com:443"
        )
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "config.json"
            target.write_text("keep", encoding="utf-8")
            with self.assertRaisesRegex(MODULE.ConfigError, "--force"):
                MODULE._write_config(config, str(target), False)
            MODULE._write_config(config, str(target), True)
            self.assertEqual(json.loads(target.read_text(encoding="utf-8")), config)


if __name__ == "__main__":
    unittest.main()
