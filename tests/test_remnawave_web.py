import importlib.util
import io
import subprocess
import sys
import tarfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("remnawave_web", ROOT / "remnawave-web.py")
assert SPEC and SPEC.loader
web = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = web
SPEC.loader.exec_module(web)


class ValidationTests(unittest.TestCase):
    def test_valid_payload_is_normalized(self):
        values = web.validate_payload(
            {
                "server_name": "Moscow-01",
                "node_ip": "203.0.113.10",
                "node_domain": "NODE.Example.COM.",
                "ssh_port": "22222",
                "country_code": "ru",
            }
        )
        self.assertEqual(values["node_domain"], "node.example.com")
        self.assertEqual(values["node_ip"], "203.0.113.10")
        self.assertEqual(values["ssh_port"], 22222)
        self.assertEqual(values["country_code"], "RU")

    def test_rejects_loopback_and_domain_injection(self):
        base = {
            "server_name": "Node-01",
            "node_ip": "127.0.0.1",
            "node_domain": "node.example.com",
            "ssh_port": 22,
            "country_code": "XX",
        }
        with self.assertRaises(web.UserVisibleError):
            web.validate_payload(base)
        base["node_ip"] = "203.0.113.10"
        base["node_domain"] = "node.example.com;touch /tmp/oops"
        with self.assertRaises(web.UserVisibleError):
            web.validate_payload(base)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.ports = {
            "reality": 443,
            "xhttp": 21001,
            "trojan": 21002,
            "shadowsocks": 21003,
            "hysteria2": 21004,
            "node": 2222,
        }

    def test_profile_contains_the_five_managed_protocols(self):
        profile = web.build_profile(
            "Moscow-01",
            "node.example.com",
            self.ports,
            "private-x25519-key",
            "0123456789abcdef",
            "/random-xhttp-path",
            "shadowsocks-server-key",
            "AUTO-A1B2C3",
        )
        inbounds = profile["inbounds"]
        self.assertEqual(len(inbounds), 5)
        self.assertEqual([item["protocol"] for item in inbounds], ["vless", "vless", "trojan", "shadowsocks", "hysteria"])
        self.assertEqual(
            [item["port"] for item in inbounds],
            [self.ports[key] for key in ("reality", "xhttp", "trojan", "shadowsocks", "hysteria2")],
        )
        self.assertEqual(inbounds[0]["settings"]["flow"], "xtls-rprx-vision")
        self.assertEqual(inbounds[0]["streamSettings"]["realitySettings"]["target"], "/dev/shm/nginx.sock")
        self.assertEqual(inbounds[1]["streamSettings"]["xhttpSettings"], {"path": "/random-xhttp-path", "host": "node.example.com", "mode": "auto"})
        self.assertNotIn("extra", inbounds[1]["streamSettings"]["xhttpSettings"])
        for index in (1, 2, 4):
            certificates = inbounds[index]["streamSettings"]["tlsSettings"]["certificates"]
            self.assertEqual(certificates[0]["certificateFile"], "/etc/letsencrypt/live/node.example.com/fullchain.pem")

    def test_archive_is_root_only_and_contains_no_ssh_password(self):
        old_cidr = web.PANEL_SOURCE_CIDR
        web.PANEL_SOURCE_CIDR = "198.51.100.5/32"
        try:
            archive = web.build_payload_archive("node-secret", "node.example.com", 22, self.ports)
        finally:
            web.PANEL_SOURCE_CIDR = old_cidr
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
            names = set(bundle.getnames())
            self.assertIn("opt/remnanode/docker-compose.yml", names)
            self.assertIn("opt/remnanode/.managed-by-remnawave-web", names)
            self.assertIn("usr/local/sbin/remnawave-node-install", names)
            compose_member = bundle.getmember("opt/remnanode/docker-compose.yml")
            env_member = bundle.getmember("opt/remnanode/node.env")
            self.assertEqual(compose_member.mode, 0o600)
            self.assertEqual(env_member.mode, 0o600)
            compose = bundle.extractfile(compose_member).read().decode()
            all_bytes = b"".join(bundle.extractfile(member).read() for member in bundle.getmembers() if member.isfile())
        self.assertIn("node-secret", compose)
        self.assertIn("./html:/var/www/html:ro", compose)
        self.assertNotIn(b"root_password", all_bytes)
        self.assertNotIn(b"sshpass", all_bytes)

    def test_remote_installer_has_valid_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n"], input=web.REMOTE_INSTALL_SCRIPT.encode(), capture_output=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn("[[ ! -e /opt/remnanode ]]", web.PREFLIGHT_SCRIPT)


class SecurityTests(unittest.TestCase):
    def test_log_sanitizer_redacts_known_secret_and_assignments(self):
        value = web.sanitize_log(
            "Authorization: Bearer abc password=hunter2 SECRET_KEY=hidden", ("abc",)
        )
        self.assertNotIn("abc", value)
        self.assertNotIn("hunter2", value)
        self.assertNotIn("hidden", value)
        self.assertIn("[REDACTED]", value)

    def test_port_selection_never_reuses_a_listener(self):
        ports = web.select_ports({8000, 23456})
        self.assertEqual(ports["reality"], 443)
        self.assertEqual(ports["node"], 2222)
        self.assertEqual(len(set(ports.values())), 6)
        self.assertFalse(set(ports.values()) & {8000, 23456})

    def test_port_selection_moves_node_api_when_default_is_busy(self):
        ports = web.select_ports({2222})
        self.assertNotEqual(ports["node"], 2222)
        self.assertNotIn(ports["node"], {443, ports["xhttp"], ports["trojan"], ports["shadowsocks"], ports["hysteria2"]})


if __name__ == "__main__":
    unittest.main()
