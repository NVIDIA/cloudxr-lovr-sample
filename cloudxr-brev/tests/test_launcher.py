import importlib.util
import json
import os
import socket
import stat
import subprocess
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_launch", ROOT / "scripts/build_launch.py")
BUILD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(BUILD)

PREVIEW_SPEC = importlib.util.spec_from_file_location("build_preview", ROOT / "scripts/build_preview.py")
PREVIEW = importlib.util.module_from_spec(PREVIEW_SPEC)
assert PREVIEW_SPEC.loader
PREVIEW_SPEC.loader.exec_module(PREVIEW)


class LauncherTests(unittest.TestCase):
    def run_shell(self, script, directory, **extra):
        env = os.environ | {"CLOUDXR_STATE": directory} | extra
        return subprocess.run(
            ["bash", "-c", script], cwd=ROOT, env=env, text=True, capture_output=True
        )

    def fixture_env(self, base, **overrides):
        fixture = Path(base) / "probe.json"
        state = Path(base) / "state"
        values = {
            "driver_version": "610.43.02",
            "os_id": "ubuntu",
            "os_version": "24.04",
            "machine": "x86_64",
            "system": "Linux",
            "gpus": [{"index": 0, "name": "NVIDIA L40S", "memory_mib": 46068, "nvenc": True}],
        }
        values.update(overrides)
        fixture.write_text(json.dumps(values))
        state.mkdir()
        (state / "versions.json").write_text(json.dumps({
            "runtime": ["6.2.3", "6.2.1", "6.2.0", "6.0.5", "6.0.4", "6.0.2"],
            "js": ["6.2.0", "6.1.0"],
            "framework": ["6.2.0", "6.1.0", "6.0.4", "6.0.3", "6.0.2"],
        }))
        return os.environ | {
            "CLOUDXR_STATE": str(state),
            "CLOUDXR_PROBE_FIXTURE": str(fixture),
        }

    def test_generated_artifact_is_deterministic_and_within_brev_limit(self):
        artifact = BUILD.build("1" * 40)
        self.assertEqual(artifact, BUILD.build("1" * 40))
        self.assertTrue(artifact.startswith(b"#!/bin/bash\n"))
        self.assertLessEqual(len(artifact), 16 * 1024)

    def test_preview_reuses_ui_and_injects_interactive_mock(self):
        preview = PREVIEW.build()
        self.assertIn('<script src="mock.js"></script>\n<script>', preview)
        self.assertEqual(preview.count('<script src="mock.js"></script>'), 1)
        mock = PREVIEW.MOCK.read_text()
        for endpoint in ("/api/status", "/api/logs", "/api/log", "/api/start", "/api/stop"):
            self.assertIn(endpoint, mock)
        self.assertIn("INTERACTIVE MOCK", mock)
        self.assertIn("framework:['6.2.0'", mock)

    def test_payload_has_latest_main_flavors_logs_and_official_logo(self):
        launcher = (ROOT / "src/launcher.sh").read_bytes()
        page = (ROOT / "src/ui.html").read_bytes()
        manifest = BUILD.source_manifest()
        self.assertEqual(set(manifest), set(BUILD.NAMES))
        self.assertIn(b"https://github.com/NVIDIA/cloudxr-lovr-sample.git", launcher)
        self.assertIn(b"fetch --quiet --depth 1 origin main", launcher)
        self.assertIn(b"CLOUDXR_RUNTIME_VERSION", launcher)
        self.assertIn(b"CLOUDXR_JS_VERSION", launcher)
        self.assertIn(b"cloudxr-runtime/versions/$version/files", launcher)
        self.assertIn(b"Linux*-sdk.tar.gz", launcher)
        self.assertIn(b"-DLOVR_PLUGINS=plugins/nvidia", launcher)
        self.assertIn(b'--device-profile="$apple_profile"', launcher)
        self.assertIn(b"apple-vision-pro", launcher)
        self.assertIn(b"ipad-pro", launcher)
        self.assertIn(b"--device-profile=auto-webrtc", launcher)
        self.assertNotIn(b"./build.sh Release --without-cloudxrjs", launcher)
        self.assertIn(b"NV_CXR_FILE_LOGGING=false", launcher)
        self.assertIn(b"NV_CXR_ENDPOINT_IP", launcher)
        self.assertIn(b"NV_CXR_MEDIA_PORT", launcher)
        self.assertIn(b"VK_ICD_FILENAMES", launcher)
        self.assertIn(b"vulkaninfo --summary", launcher)
        self.assertIn(b"CLOUDXR_UPGRADE_GPU_DRIVER", launcher)
        self.assertIn(b"CLOUDXR_DEFAULT_MODE", launcher)
        for removed in (b"CLOUDXR_AUTO_START", b"CLOUDXR_DEFAULT_RUNTIME", b"CLOUDXR_DEFAULT_JS",
                        b"CLOUDXR_DEFAULT_FRAMEWORK", b"CLOUDXR_RUNTIME_VERSIONS",
                        b"CLOUDXR_JS_VERSIONS", b"CLOUDXR_FRAMEWORK_VERSIONS", b"CLOUDXR_UI_PORT"):
            self.assertNotIn(removed, launcher)
        self.assertIn(b"cloudxr-experiences.service", launcher)
        self.assertIn(b"UI_PORT=8080", launcher)
        self.assertIn(b"acl signaling path_beg /signal", launcher)
        self.assertIn(b"replace-path ^/signal/[^/]+(/.*)$ \\1", launcher)
        self.assertIn(b"server runtime 127.0.0.1:49100", launcher)
        self.assertIn(b"location.origin+'/signal'", launcher)
        self.assertNotIn(b"tls.crt", launcher)
        self.assertIn(b"/api/log", launcher)
        self.assertIn(b"https://brev.nvidia.com/logos/svg/nvidia-white-text.svg", page)
        self.assertIn(b'<select id="runtime">', page)
        self.assertIn(b'<select id="js">', page)
        self.assertIn(b'<select id="framework">', page)
        self.assertIn(b"CloudXR.js - WebXR on Any Browser", page)
        self.assertIn(b"Apple Native Client", page)
        self.assertIn(b"mode='webxr'", page)
        self.assertIn(b'<input id="logSearch"', page)
        self.assertIn(b"input{flex:1", page)
        self.assertIn(b"toLowerCase().includes", page)
        self.assertNotIn(b"scrollHeight", page)

    def test_catalog_reports_hardware_and_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.fixture_env(directory)
            state = Path(env["CLOUDXR_STATE"])
            (state / "source.commit").write_text("abcdef1234567890\n")
            result = subprocess.run(
                ["bash", ROOT / "src/launcher.sh", "catalog"], env=env, text=True, capture_output=True
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            catalog = json.loads(result.stdout)
            self.assertTrue(catalog["runnable"])
            self.assertEqual(catalog["versions"]["runtime"][0], "6.2.3")
            self.assertEqual(catalog["gpus"][0]["name"], "NVIDIA L40S")

    def test_catalog_discovers_and_caches_ngc_and_github_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            base, tools = Path(directory), Path(directory) / "tools"
            tools.mkdir()
            curl = tools / "curl"
            curl.write_text(r'''#!/bin/sh
case "$*" in
  *cloudxr-runtime*) printf '%s' '{"recipeVersions":[{"versionId":"6.3.0","status":"UPLOAD_COMPLETE"},{"versionId":"invalid","status":"UPLOAD_COMPLETE"}]}' ;;
  *cloudxr-js*) printf '%s' '{"recipeVersions":[{"versionId":"6.3.0","status":"UPLOAD_COMPLETE"}]}' ;;
  *) exit 1 ;;
esac
''')
            git = tools / "git"
            git.write_text("#!/bin/sh\nprintf 'abc\\trefs/tags/6.3.0\\nabc\\trefs/tags/5.0.1\\n'\n")
            curl.chmod(0o755); git.chmod(0o755)
            env = self.fixture_env(directory) | {
                "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
            }
            state = Path(env["CLOUDXR_STATE"])
            result = subprocess.run(
                ["bash", ROOT / "src/launcher.sh", "catalog", "--refresh"], env=env, text=True, capture_output=True
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            catalog = json.loads(result.stdout)
            self.assertEqual(catalog["versions"]["runtime"][0], "6.3.0")
            self.assertEqual(catalog["versions"]["js"][0], "6.3.0")
            self.assertEqual(catalog["versions"]["framework"][0], "6.3.0")
            self.assertEqual(catalog["versions"]["runtime"], ["6.3.0"])
            self.assertNotIn("5.0.1", catalog["versions"]["framework"])
            self.assertTrue((state / "versions.json").is_file())
            latest = subprocess.run(
                ["bash", ROOT / "src/launcher.sh", "catalog", "--latest"], env=env, text=True, capture_output=True
            )
            self.assertEqual(latest.returncode, 0, latest.stderr)
            self.assertEqual(latest.stdout.strip(), "6.3.0 6.3.0 6.3.0")

    def test_catalog_blocks_old_driver_and_compute_only_gpu(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.fixture_env(
                directory,
                driver_version="565.57.01",
                gpus=[{"index": 0, "name": "NVIDIA H100", "memory_mib": 81920, "nvenc": False}],
            )
            result = subprocess.run(
                ["bash", ROOT / "src/launcher.sh", "catalog", "--check"],
                env=env,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("driver 580+", result.stderr)
            self.assertIn("NVENC-capable", result.stderr)

    def test_flavor_validation_enforces_mode_specific_compatibility(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix = "set -- help; source src/launcher.sh >/dev/null; "
            ok = self.run_shell(prefix + "validate_flavor apple 6.0.2 6.1.0 6.2.0", directory)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            old = self.run_shell(prefix + "validate_flavor webxr 6.0.4 6.1.0 6.2.0", directory)
            self.assertNotEqual(old.returncode, 0)
            self.assertIn("Runtime 6.0.5+", old.stderr)
            mixed = self.run_shell(prefix + "validate_flavor webxr 6.2.1 7.0.0 6.2.0", directory)
            self.assertNotEqual(mixed.returncode, 0)
            self.assertIn("same major", mixed.stderr)

    def test_dependencies_install_matching_server_graphics_and_nvenc_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''set -- help
source src/launcher.sh >/dev/null
grep() { [[ "$*" == *ID=ubuntu* ]] && return 0; command grep "$@"; }
dpkg-query() { [[ "$*" == *libnvidia-compute* ]] && echo 580.173.02-1 || echo 'ii  nvidia-driver-580-server'; }
sudo() { printf '%s\n' "$*" >> "$CLOUDXR_STATE/calls"; }
ensure_build_dependencies
'''
            result = self.run_shell(script, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = (Path(directory) / "calls").read_text()
            self.assertIn("libnvidia-gl-580-server", calls)
            self.assertIn("libnvidia-encode-580-server", calls)
            self.assertIn("nvidia-utils-580-server=580.173.02-1", calls)

    def test_dependencies_use_loaded_driver_for_provider_managed_gpu(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''set -- help
source src/launcher.sh >/dev/null
grep() { [[ "$*" == *ID=ubuntu* ]] && return 0; [[ "$*" == *nvidia/version* ]] && echo 595.84; }
nvidia-smi() { return 127; }
dpkg-query() { [[ "$*" == *libnvidia-compute* ]] && echo 595.84-1 || return 1; }
sudo() { printf '%s\n' "$*" >> "$CLOUDXR_STATE/calls"; }
ensure_build_dependencies
'''
            result = self.run_shell(script, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = (Path(directory) / "calls").read_text()
            self.assertIn("nvidia-utils-595=595.84-1", calls)
            self.assertIn("libnvidia-gl-595=595.84-1", calls)
            self.assertIn("libnvidia-encode-595=595.84-1", calls)
            self.assertNotIn("nvidia-gl-390", calls)

    def test_gpu_upgrade_installs_recommended_driver_and_schedules_reboot(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''set -- help
source src/launcher.sh >/dev/null
grep() { [[ "$*" == *ID=ubuntu* ]] && return 0; command grep "$@"; }
nvidia-smi() { echo 565.57.01; }
ubuntu-drivers() { echo 'driver : nvidia-driver-595-server-open - distro non-free recommended'; }
dpkg-query() { printf 'nvidia-driver-565-server\nlibnvidia-compute-565-server\n'; }
sudo() { printf '%s\n' "$*" >> "$CLOUDXR_STATE/calls"; }
install_boot_service() { echo boot >> "$CLOUDXR_STATE/calls"; }
upgrade_gpu_driver
printf '%s\n' "$REBOOT_SCHEDULED" > "$CLOUDXR_STATE/scheduled"
'''
            result = self.run_shell(script, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = (Path(directory) / "calls").read_text()
            self.assertIn("apt-get remove", calls)
            self.assertIn("nvidia-driver-595-server-open", calls)
            self.assertIn("libnvidia-gl-595-server", calls)
            self.assertIn("libnvidia-encode-595-server", calls)
            self.assertIn("shutdown -r +1", calls)
            self.assertEqual((Path(directory) / "scheduled").read_text().strip(), "1")
            self.assertTrue((Path(directory) / "gpu-reboot").exists())

    def test_current_gpu_driver_clears_reboot_guard_without_installing(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "gpu-reboot"
            marker.touch()
            script = r'''set -- help
source src/launcher.sh >/dev/null
grep() { return 0; }
nvidia-smi() { echo 580.173.02; }
sudo() { return 99; }
upgrade_gpu_driver
'''
            result = self.run_shell(script, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())

    def test_gpu_upgrade_guard_prevents_reboot_loop(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "gpu-reboot").touch()
            script = r'''set -- help
source src/launcher.sh >/dev/null
grep() { return 0; }
nvidia-smi() { echo 565.57.01; }
upgrade_gpu_driver
'''
            result = self.run_shell(script, directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("failed after reboot", result.stderr)

    def test_boot_service_resumes_setup_as_launch_user(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''set -- help
source src/launcher.sh >/dev/null
RUN_USER=brev
sudo() {
  if [[ "$2" == tee ]]; then command cat > "$CLOUDXR_STATE/unit";
  else printf '%s\n' "$*" >> "$CLOUDXR_STATE/calls"; fi
}
install_boot_service
'''
            result = self.run_shell(script, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            unit = (Path(directory) / "unit").read_text()
            self.assertIn("User=brev", unit)
            self.assertIn(f"ExecStart={ROOT / 'src/launcher.sh'} setup", unit)
            calls = (Path(directory) / "calls").read_text()
            self.assertIn("systemctl enable cloudxr-experiences.service", calls)

    def test_start_validates_then_stops_and_records_full_flavor(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''set -- help
source src/launcher.sh >/dev/null
catalog() { echo check >> "$CLOUDXR_STATE/calls"; }
stop_locked() { echo stop >> "$CLOUDXR_STATE/calls"; }
nohup() { :; }
sleep() { :; }
pid_alive() { return 0; }
start_flavor webrtc 6.2.1 6.2.0 6.2.0
'''
            result = self.run_shell(script, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((Path(directory) / "calls").read_text().splitlines(), ["check", "stop"])
            self.assertEqual((Path(directory) / "current.mode").read_text().strip(), "webxr")
            self.assertEqual((Path(directory) / "current.runtime").read_text().strip(), "6.2.1")
            self.assertEqual((Path(directory) / "current.js").read_text().strip(), "6.2.0")
            self.assertEqual((Path(directory) / "current.framework").read_text().strip(), "6.2.0")

    def test_setup_always_autostarts_webrtc_with_latest_catalog_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''set -- help
source src/launcher.sh >/dev/null
uname() { echo Linux; }
setsid() { :; }
sudo() { :; }
upgrade_gpu_driver() { :; }
ensure_build_dependencies() { :; }
ensure_source() { echo latest-main > "$SOURCE_COMMIT_FILE"; }
catalog() { if [[ "$1" == --latest ]]; then echo '6.3.0 6.3.0 6.2.0'; fi; }
start_ui() { :; }
pid_alive() { return 1; }
start_flavor() { printf '%s\n' "$*" > "$CLOUDXR_STATE/autostart"; }
setup
'''
            result = self.run_shell(script, directory, CLOUDXR_AUTO_START="0")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((Path(directory) / "autostart").read_text().strip(), "webrtc 6.3.0 6.3.0 6.2.0")

    def test_start_does_not_deploy_after_hardware_validation_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''set -- help
source src/launcher.sh >/dev/null
catalog() { echo 'missing GPU' >&2; return 1; }
stop_locked() { touch "$CLOUDXR_STATE/stopped"; }
start_flavor webxr 6.2.1 6.2.0 6.2.0
'''
            result = self.run_shell(script, directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("hardware validation failed", result.stderr)
            self.assertFalse((Path(directory) / "stopped").exists())

    def test_stop_clears_stale_lock_from_managed_runtime_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "xdg-runtime"
            runtime.mkdir()
            (runtime / "runtime_started").touch()
            result = self.run_shell(
                "set -- help; source src/launcher.sh >/dev/null; stop_locked",
                directory,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((runtime / "runtime_started").exists())

    def test_cached_flavor_skips_rebuild(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "sample"
            example = root / "plugins/nvidia/examples/cloudxr"
            example.mkdir(parents=True)
            for name in ("build.sh", "run.sh"):
                path = root / name
                path.write_text("#!/bin/bash\nexit 99\n")
                path.chmod(0o755)
            (example / "main.lua").write_text("-- test\n")
            output = root / "build/bin"
            output.mkdir(parents=True)
            (output / "lovr").write_text("#!/bin/bash\n")
            (output / "lovr").chmod(0o755)
            (output / "openxr_cloudxr.json").write_text("{}\n")
            client = root / "build/cloudxr/cloudxr-js-samples/react/build"
            client.mkdir(parents=True)
            (client / "index.html").write_text("web client\n")
            (root / ".brev-ready").write_text("local webxr 6.2.1 6.2.0\n")
            script = r'''set -- help
source src/launcher.sh >/dev/null
ensure_build_dependencies() { echo rebuilt > "$CLOUDXR_STATE/rebuilt"; }
ensure_flavor apple 6.2.1 6.2.0
'''
            state = base / "state"
            state.mkdir()
            (state / "source.commit").write_text("local\n")
            result = self.run_shell(script, str(state), CLOUDXR_LOVR_ROOT=str(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((state / "rebuilt").exists())
            self.assertEqual((state / "current.flavor").read_text().strip(), str(root))

    def test_runtime_archive_name_comes_from_ngc_file_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "sample"
            root.mkdir()
            script = r'''set -- help
source src/launcher.sh >/dev/null
curl() {
  if [[ "$*" == *"/versions/6.2.3/files"* ]]; then
    printf '%s' '{"recipeFiles":[{"path":"CloudXR-6.2.3-Linux-arm64-sdk.tar.gz"},{"path":"CloudXR-6.2.3-Linux-amd64-sdk.tar.gz"}]}'
    return
  fi
  printf '%s\n' "$*" >> "$CLOUDXR_STATE/downloads"
  local output=""
  while (( $# )); do if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi; done
  printf archive > "$output"
}
ensure_runtime_archive "$TEST_ROOT" 6.2.3
ensure_runtime_archive "$TEST_ROOT" 6.2.3
'''
            result = self.run_shell(script, directory, TEST_ROOT=str(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            archive = root / "build/cloudxr/CloudXR-6.2.3-Linux-amd64-sdk.tar.gz"
            self.assertEqual(archive.read_text(), "archive")
            downloads = (Path(directory) / "downloads").read_text().splitlines()
            self.assertEqual(len(downloads), 1)
            self.assertIn("path=CloudXR-6.2.3-Linux-amd64-sdk.tar.gz", downloads[0])

    def test_webxr_sample_pins_declared_react_minimums(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "sample"
            package = root / "build/cloudxr/cloudxr-js-samples/react/package.json"
            package.parent.mkdir(parents=True)
            package.write_text('''{
  "dependencies": {
    "react": "^19.2.5",
    "react-dom": "^19.2.5",
    "three": "^0.184.0"
  }
}\n''')
            script = r'''set -- help
source src/launcher.sh >/dev/null
ensure_js_sample "$TEST_ROOT"
'''
            result = self.run_shell(script, directory, TEST_ROOT=str(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            dependencies = json.loads(package.read_text())["dependencies"]
            self.assertEqual(dependencies["react"], "19.2.5")
            self.assertEqual(dependencies["react-dom"], "19.2.5")
            self.assertEqual(dependencies["three"], "^0.184.0")

    def test_apple_and_webrtc_share_server_build_key(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''set -- help
source src/launcher.sh >/dev/null
flavor_path apple 6.2.1 6.2.0 abcdef1234567890
flavor_path webxr 6.2.1 6.2.0 abcdef1234567890
'''
            result = self.run_shell(script, directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            paths = result.stdout.splitlines()
            self.assertEqual(paths[0], paths[1])
            self.assertIn("abcdef123456-webxr-rt-6.2.1-js-6.2.0", paths[0])

    def test_run_flavor_uses_headless_native_and_webrtc(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, state = base / "flavor", base / "state"
            root.mkdir(); state.mkdir()
            icd = root / "docker/data/nvidia_icd.json"
            icd.parent.mkdir(parents=True)
            icd.write_text('{"library_path":"libGLX_nvidia.so.0"}\n')
            run = root / "run.sh"
            run.write_text('#!/bin/bash\nprintf "%s\\n%s\\n%s\\n%s\\n%s\\n" "$*" "$XDG_RUNTIME_DIR" "$VK_ICD_FILENAMES" "$NV_CXR_ENDPOINT_IP" "$NV_CXR_MEDIA_PORT" > "$CLOUDXR_STATE/args"\n')
            run.chmod(0o755)
            fake_self = base / "fake-web"
            fake_self.write_text("#!/bin/bash\ntrap 'exit 0' TERM\nwhile :; do sleep 1; done\n")
            fake_self.chmod(0o755)
            prefix = r'''set -- help
source src/launcher.sh >/dev/null
SELF="$TEST_SELF"
curl() { [[ "$*" == *api.ipify.org* ]] && printf '203.0.113.10'; return 0; }
vulkaninfo() { return 0; }
export NV_CXR_ENDPOINT_IP=203.0.113.10 NV_CXR_MEDIA_PORT=47998
'''
            web = self.run_shell(
                prefix + 'run_flavor webxr "$TEST_ROOT"', str(state),
                TEST_SELF=str(fake_self), TEST_ROOT=str(root),
            )
            self.assertEqual(web.returncode, 0, web.stderr)
            web_args = (state / "args").read_text()
            self.assertIn("--headless", web_args)
            self.assertIn("--without-cloudxrjs", web_args)
            self.assertIn("--device-profile=auto-webrtc", web_args)
            self.assertNotIn("--cert", web_args)
            self.assertIn(str(state / "xdg-runtime"), web_args)
            generated_icd = state / "nvidia_icd.json"
            self.assertIn(str(generated_icd), web_args)
            self.assertIn("libEGL_nvidia.so.0", generated_icd.read_text())
            self.assertIn("203.0.113.10", web_args)
            self.assertIn("47998", web_args)
            self.assertEqual((state / "current.endpoint").read_text().strip(), "203.0.113.10")
            self.assertEqual((state / "xdg-runtime").stat().st_mode & 0o777, 0o700)
            apple = self.run_shell(
                prefix + 'run_flavor apple "$TEST_ROOT"', str(state),
                TEST_SELF=str(fake_self), TEST_ROOT=str(root),
            )
            self.assertEqual(apple.returncode, 0, apple.stderr)
            apple_args = (state / "args").read_text()
            self.assertIn("--headless --device-profile=apple-vision-pro", apple_args)
            self.assertNotIn("--cert", apple_args)
            ipad = self.run_shell(prefix + 'run_flavor apple "$TEST_ROOT" ipad-pro', str(state),
                                  TEST_SELF=str(fake_self), TEST_ROOT=str(root))
            self.assertEqual(ipad.returncode, 0, ipad.stderr)
            self.assertIn("--device-profile=ipad-pro", (state / "args").read_text())

    def test_http_ui_exposes_status_and_incremental_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            env = self.fixture_env(directory)
            state = Path(env["CLOUDXR_STATE"])
            state.mkdir(parents=True, exist_ok=True)
            (state / "source.commit").write_text("6b30ddc1c20117a414d2eb5068686ad6b0fe3a31\n")
            (state / "current.mode").write_text("webxr\n")
            (state / "current.runtime").write_text("6.2.1\n")
            (state / "current.js").write_text("6.2.0\n")
            (state / "current.framework").write_text("6.2.0\n")
            (state / "current.endpoint").write_text("203.0.113.10\n")
            (state / "current.phase").write_text("starting\n")
            (state / "server.log").write_text("Runtime is now running and accepting connections\n" + "old log line\n" * 10000)
            (state / "proxy.log").write_text("Secure Link route ready\n")
            with socket.socket() as sock:
                try: sock.bind(("127.0.0.1", 0))
                except PermissionError: self.skipTest("local sandbox blocks listening sockets")
                port = sock.getsockname()[1]
            sleeper = subprocess.Popen(["sleep", "30"])
            (state / "deploy.pid").write_text(f"{sleeper.pid}\n")
            env.pop("USER", None)
            server = subprocess.Popen(
                ["bash", ROOT / "src/launcher.sh", "_http", str(port)], env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            )
            try:
                for _ in range(50):
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/status") as response:
                            status = json.load(response)
                        break
                    except OSError: time.sleep(0.05)
                else: self.fail(server.stderr.read())
                self.assertEqual(status["process"]["state"], "ready")
                self.assertEqual(status["network"]["settings"]["deployment_mode"], "direct")
                self.assertEqual(status["process"]["apple_profile"], "apple-vision-pro")
                self.assertEqual(status["process"]["device_profile"], "auto-webrtc")
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz") as response:
                    self.assertTrue(json.load(response)["ready"])
                self.assertEqual(status["process"]["runtime"], "6.2.1")
                self.assertEqual(status["process"]["endpoint"], "203.0.113.10")
                self.assertEqual((state / "current.phase").read_text().strip(), "ready")
                (state / "server.log").write_text("continuing runtime output\n" * 10000)
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/status") as response:
                    status = json.load(response)
                self.assertEqual(status["process"]["state"], "ready")
                (state / "server.log").write_text("ERROR service->start() failed: test\n")
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/status") as response:
                    status = json.load(response)
                self.assertEqual(status["process"]["state"], "failed")
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/log?id=proxy&offset=0") as response:
                    log = json.load(response)
                self.assertIn("Secure Link route ready", log["text"])
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/") as response:
                    self.assertIn(b"nvidia-white-text.svg", response.read())
            finally:
                server.terminate(); server.wait(timeout=5); server.stderr.close()
                sleeper.terminate(); sleeper.wait(timeout=5)

    def test_http_ui_serves_web_client_with_secure_link_defaults(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            state = base / "state"
            state.mkdir()
            with socket.socket() as sock:
                try: sock.bind(("127.0.0.1", 0))
                except PermissionError: self.skipTest("local sandbox blocks listening sockets")
                port = sock.getsockname()[1]
            flavor = base / "flavor"
            built = flavor / "build/cloudxr/cloudxr-js-samples/react/build"
            built.mkdir(parents=True)
            (built / "index.html").write_text("<html><head></head><body>CloudXR.js</body></html>")
            (built / "bundle.js").write_text("console.log('ok')\n")
            (state / "current.flavor").write_text(f"{flavor}\n")
            env = os.environ | {"CLOUDXR_STATE": str(state)}
            server = subprocess.Popen(
                ["bash", ROOT / "src/launcher.sh", "_http", str(port)], env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            )
            try:
                for _ in range(50):
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/webxr/") as response:
                            page = response.read()
                        break
                    except OSError: time.sleep(0.05)
                else: self.fail(server.stderr.read())
                self.assertIn(b"localStorage.setItem('port','443')", page)
                self.assertIn(b"localStorage.setItem('serverIp',location.hostname)", page)
                self.assertIn(b"localStorage.setItem('proxyUrl',location.origin+'/signal')", page)
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/webxr/bundle.js") as response:
                    self.assertEqual(response.headers["Cache-Control"], "no-store")
            finally:
                server.terminate(); server.wait(timeout=5); server.stderr.close()


if __name__ == "__main__":
    unittest.main()
