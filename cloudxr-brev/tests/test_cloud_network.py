import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "src/cloud-network.py"
SPEC = importlib.util.spec_from_file_location("cloud_network", HELPER)
NETWORK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NETWORK)


class CloudNetworkTests(unittest.TestCase):
    def helper(self, action, state, *args, **env):
        return subprocess.run([sys.executable, str(HELPER), action, str(state), *map(str, args)],
                              env=os.environ | env, capture_output=True, text=True)

    def test_new_state_defaults_to_original_and_old_cloud_state_migrates(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            self.assertEqual(NETWORK.settings(state)["deployment_mode"], "direct")
            (state / "network.json").write_text('{"stun_mode":"local"}')
            self.assertEqual(NETWORK.settings(state)["deployment_mode"], "cloud")
            (state / "network.json").write_text('{"deployment_mode":"direct"}')
            self.assertEqual(NETWORK.settings(state)["deployment_mode"], "direct")

    def test_original_mode_ignores_cloud_settings_and_uses_original_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.helper("save", directory, "external", "invalid", "invalid", "bad", "bad", "direct")
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.helper("prepare", directory, NV_CXR_ENDPOINT_IP="192.168.1.2", NV_CXR_MEDIA_PORT="48000")
            self.assertEqual(result.returncode, 0, result.stderr)
            current = json.loads((Path(directory) / "current.network.json").read_text())
            self.assertIsNone(current["enable_ice"])
            self.assertEqual((current["public_ip"], current["media_port"], current["stun_port"]),
                             ("192.168.1.2", 48000, 0))

    def test_cloud_local_and_external_stun_are_prepared(self):
        with tempfile.TemporaryDirectory() as directory:
            for mode, host in (("local", ""), ("external", "1.1.1.1")):
                result = self.helper("save", directory, mode, "8.8.8.8", host, 3478, 47998, "cloud")
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.helper("prepare", directory, NV_CXR_ENDPOINT_IP="192.168.1.2")
                self.assertEqual(result.returncode, 0, result.stderr)
                current = json.loads((Path(directory) / "current.network.json").read_text())
                self.assertIs(current["enable_ice"], True)
                self.assertEqual(current["public_ip"], "8.8.8.8")
                self.assertEqual(current["stun_ip"], "127.0.0.1" if mode == "local" else host)

    def test_invalid_cloud_settings_do_not_overwrite_saved_state(self):
        with tempfile.TemporaryDirectory() as directory:
            self.helper("save", directory)
            original = (Path(directory) / "network.json").read_bytes()
            for args in (("local", "127.0.0.1", "", 3478, 47998, "cloud"),
                         ("external", "", "invalid", 3478, 47998, "cloud"),
                         ("local", "", "", 47998, 47998, "cloud")):
                self.assertNotEqual(self.helper("save", directory, *args).returncode, 0)
                self.assertEqual((Path(directory) / "network.json").read_bytes(), original)

    def test_stun_response_preserves_port_transaction_and_fingerprint(self):
        cookie = NETWORK.COOKIE
        transaction = bytes(range(12))
        request = struct.pack("!HHI", 1, 0, cookie) + transaction
        response = NETWORK.binding_response(request, ("127.0.0.1", 47998), "8.8.8.8")
        self.assertEqual(response[8:20], transaction)
        kind, size, _, family, port, address = struct.unpack("!HHBBHI", response[32:44])
        self.assertEqual((kind, size, family), (0x20, 8, 1))
        self.assertEqual(port ^ (cookie >> 16), 47998)
        self.assertEqual(address ^ cookie, int(NETWORK.ipaddress.IPv4Address("8.8.8.8")))
        self.assertEqual(struct.unpack("!I", response[-4:])[0],
                         (zlib.crc32(response[:-8]) & 0xffffffff) ^ 0x5354554e)
        for bad in (b"", request[:-1], request + b"x", b"\x01\x01" + request[2:]):
            self.assertIsNone(NETWORK.binding_response(bad, ("127.0.0.1", 1), "8.8.8.8"))

    def test_runtime_hook_is_idempotent_and_rejects_changed_upstream_source(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "plugins/nvidia/examples/cloudxr/cloudxr_manager.lua"
            target.parent.mkdir(parents=True)
            target.write_text("    -- Start the CloudXR service - this begins the streaming process\n")
            for _ in range(2):
                result = self.helper("patch", directory)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(target.read_text().count("-- Brev cloud network configuration"), 1)
            target.write_text("changed upstream startup\n")
            self.assertNotEqual(self.helper("patch", directory).returncode, 0)
            self.assertEqual(target.read_text(), "changed upstream startup\n")

    def test_profile_validation_precedes_stopping_running_flavor(self):
        with tempfile.TemporaryDirectory() as directory:
            script = '''set -- help
source src/launcher.sh >/dev/null
stop_locked() { touch "$CLOUDXR_STATE/stopped"; }
start_flavor apple 6.2.3 6.4.0 6.2.0 local "" "" 3478 47998 direct invalid
'''
            result = subprocess.run(["bash", "-c", script], cwd=ROOT, env=os.environ | {"CLOUDXR_STATE": directory},
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Apple profile must be", result.stderr)
            self.assertFalse((Path(directory) / "stopped").exists())

    def test_saved_ipad_preference_survives_webxr_switch(self):
        with tempfile.TemporaryDirectory() as directory:
            script = '''set -- help
source src/launcher.sh >/dev/null
catalog() { :; }
stop_locked() { :; }
nohup() { printf '%s\\n' "$*" > "$CLOUDXR_STATE/deploy.args"; }
sleep() { :; }
pid_alive() { return 0; }
start_flavor apple 6.2.3 6.4.0 6.2.0 local "" "" 3478 47998 direct ipad-pro
[[ "$(cat "$DEVICE_PROFILE_FILE")" == ipad-pro ]]
start_flavor webxr 6.2.3 6.4.0 6.2.0
[[ "$(cat "$DEVICE_PROFILE_FILE")" == auto-webrtc ]]
[[ "$(cat "$APPLE_PROFILE_FILE")" == ipad-pro ]]
'''
            result = subprocess.run(["bash", "-c", script], cwd=ROOT, env=os.environ | {"CLOUDXR_STATE": directory},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
