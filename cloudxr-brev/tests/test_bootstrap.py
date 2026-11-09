import contextlib
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("bootstrap_build", ROOT / "scripts/build_launch.py")
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)
REVISION = "1234567890abcdef" * 2 + "12345678"


class BootstrapTests(unittest.TestCase):
    def test_bootstrap_pins_revision_and_every_file_without_embedding_sources(self):
        artifact = BUILD.build(REVISION)
        self.assertEqual(artifact, BUILD.build(REVISION))
        self.assertLessEqual(len(artifact), BUILD.LIMIT)
        self.assertTrue(artifact.startswith(b"#!/bin/bash\n"))
        self.assertIn(f"/{REVISION}/cloudxr-brev/src".encode(), artifact)
        self.assertNotIn(b"/main/", artifact)
        for name, (digest, size) in BUILD.source_manifest().items():
            self.assertIn(name.encode(), artifact)
            self.assertIn(digest.encode(), artifact)
            self.assertIn(str(size).encode(), artifact)
        self.assertNotIn(b"class Handler", artifact)

    def test_revision_and_repository_paths_cannot_be_mutable_or_escape(self):
        for revision in ("main", "v1.0.0", "abc123", "A" * 40, "../" + "1" * 40):
            with self.assertRaises(ValueError):
                BUILD.build(revision)
        for repository in ("../repo", "NVIDIA/cloudxr-lovr-sample;false", "https://github.com/NVIDIA/repo"):
            with self.assertRaises(ValueError):
                BUILD.build(REVISION, repository)
        for path in ("../src", "/src", "cloudxr-brev/../../src", ""):
            with self.assertRaises(ValueError):
                BUILD.build(REVISION, source_path=path)

    def test_generated_shell_and_python_syntax(self):
        artifact = BUILD.build(REVISION)
        result = subprocess.run(["bash", "-n"], input=artifact, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        program = artifact.decode().split("<<'PY'\n", 1)[1].rsplit("\nPY\n", 1)[0]
        compile(program, "bootstrap", "exec")

    def test_release_build_requires_explicit_revision(self):
        with patch.dict(os.environ, {}, clear=True), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                BUILD.main([])
        self.assertEqual(error.exception.code, 2)

    def test_release_does_not_write_artifact_when_unpublished_or_mismatched(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "launch.sh"
            for error in (ValueError("published launcher differs"),
                          urllib.error.HTTPError("https://example.invalid", 404, "Not Found", {}, None)):
                with patch.object(BUILD, "OUTPUT", output), patch.object(BUILD, "verify_published", side_effect=error), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(BUILD.main(["--revision", REVISION]), 1)
                self.assertFalse(output.exists())

    def test_release_writes_artifact_and_checksum_only_after_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "launch.sh"
            with patch.object(BUILD, "OUTPUT", output), patch.object(BUILD, "verify_published") as verify, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(BUILD.main(["--revision", REVISION]), 0)
            verify.assert_called_once_with(BUILD.source_url(REVISION), BUILD.source_manifest())
            self.assertEqual(output.read_bytes(), BUILD.build(REVISION))
            self.assertEqual(output.with_suffix(".sh.sha256").read_text(),
                             hashlib.sha256(output.read_bytes()).hexdigest() + "  launch.sh\n")

    def test_publication_verification_checks_bytes_and_https(self):
        def response(data, url="https://raw.githubusercontent.com/source"):
            result = io.BytesIO(data)
            result.geturl = lambda: url
            return result

        base = BUILD.source_url(REVISION)
        manifest = {"launcher.sh": (hashlib.sha256(b"good").hexdigest(), 4)}
        with patch.object(urllib.request, "urlopen", return_value=response(b"good")):
            BUILD.verify_published(base, manifest)
        for data, url in ((b"bad!", "https://example.invalid"), (b"good", "http://example.invalid")):
            with patch.object(urllib.request, "urlopen", return_value=response(data, url)):
                with self.assertRaises(ValueError):
                    BUILD.verify_published(base, manifest)


class BootstrapDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sources = self.root / "sources"
        self.sources.mkdir()
        self.files = {source.name: source.read_bytes() for source in BUILD.SOURCES}
        for name, data in self.files.items():
            (self.sources / name).write_bytes(data)
        self.requests = []
        self.failed_name = None
        self.payloads = self.files.copy()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                name = self.path.rsplit("/", 1)[-1]
                owner.requests.append(name)
                if name == owner.failed_name or name not in owner.payloads:
                    self.send_error(404)
                    return
                data = owner.payloads[name]
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        try:
            self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        except PermissionError:
            self.skipTest("local sandbox blocks listening sockets")
        self.addCleanup(self.server.server_close)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(self.server.shutdown)
        self.cache = self.root / "cache"
        self.artifact = self.root / "launch.sh"
        self.prepare()

    def prepare(self, revision=REVISION):
        with patch.object(BUILD, "SOURCES", tuple(self.sources / name for name in BUILD.NAMES)):
            artifact = BUILD.build(revision)
        base = BUILD.source_url(revision)
        # Only the test copy uses local HTTP; production validates HTTPS twice.
        artifact = artifact.replace(base.encode(), f"http://127.0.0.1:{self.server.server_port}".encode())
        artifact = artifact.replace(b"response.geturl().startswith('https://')", b"response.geturl().startswith('http://127.0.0.1:')")
        self.artifact.write_bytes(artifact)
        self.artifact.chmod(0o700)

    def run_bootstrap(self, *args):
        return subprocess.run([self.artifact, *args], capture_output=True,
                              env=os.environ | {"CLOUDXR_LAUNCHER_CACHE": str(self.cache)}, timeout=15)

    def test_downloads_exact_files_and_executes_launcher(self):
        result = self.run_bootstrap("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"Usage: launcher.sh", result.stdout)
        target = self.cache / REVISION
        for name, expected in self.files.items():
            self.assertEqual((target / name).read_bytes(), expected)
        self.assertEqual((target / "launcher.sh").stat().st_mode & 0o777, 0o700)
        self.assertEqual((target / "ui.html").stat().st_mode & 0o777, 0o600)

    def test_valid_cache_works_without_any_download(self):
        self.assertEqual(self.run_bootstrap("help").returncode, 0)
        self.requests.clear()
        self.failed_name = "launcher.sh"
        self.assertEqual(self.run_bootstrap("help").returncode, 0)
        self.assertEqual(self.requests, [])

    def test_incomplete_and_modified_cache_is_repaired(self):
        self.assertEqual(self.run_bootstrap("help").returncode, 0)
        target = self.cache / REVISION
        (target / "cloud-network.py").unlink()
        (target / "ui.html").write_bytes(b"modified")
        self.assertEqual(self.run_bootstrap("help").returncode, 0)
        self.assertEqual((target / "ui.html").read_bytes(), self.files["ui.html"])
        self.assertEqual((target / "cloud-network.py").read_bytes(), self.files["cloud-network.py"])

    def test_failed_or_tampered_download_never_installs_partial_launcher(self):
        for failure in ("missing", "tampered"):
            with self.subTest(failure=failure):
                if failure == "missing":
                    self.failed_name = "cloud-network.py"
                else:
                    self.failed_name = None
                    self.payloads["cloud-runtime.lua"] = b"tampered"
                result = self.run_bootstrap("help")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"installation failed", result.stderr)
                self.assertFalse((self.cache / REVISION).exists())
                self.assertEqual(list(self.cache.glob("." + REVISION + ".*")), [self.cache / ("." + REVISION + ".lock")])

    def test_failed_promotion_restores_previous_cache(self):
        self.assertEqual(self.run_bootstrap("help").returncode, 0)
        target = self.cache / REVISION
        (target / "ui.html").write_bytes(b"previous contents")
        program = self.artifact.read_text().replace("stage.rename(target)", "raise OSError('simulated promotion failure')")
        self.artifact.write_text(program)
        result = self.run_bootstrap("help")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"simulated promotion failure", result.stderr)
        self.assertEqual((target / "ui.html").read_bytes(), b"previous contents")
        self.assertEqual((target / "launcher.sh").read_bytes(), self.files["launcher.sh"])
        self.assertFalse(list(self.cache.glob(".old-*")))

    def test_failed_rollback_preserves_previous_installation_as_backup(self):
        self.assertEqual(self.run_bootstrap("help").returncode, 0)
        target = self.cache / REVISION
        (target / "ui.html").write_bytes(b"previous contents")
        program = self.artifact.read_text().replace("stage.rename(target)", "raise OSError('simulated promotion failure')")
        program = program.replace("previous.rename(target)", "raise OSError('simulated rollback failure')")
        self.artifact.write_text(program)
        result = self.run_bootstrap("help")
        self.assertNotEqual(result.returncode, 0)
        backups = list(self.cache.glob(".old-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "ui.html").read_bytes(), b"previous contents")
        self.assertEqual((backups[0] / "launcher.sh").read_bytes(), self.files["launcher.sh"])

    def test_failed_repair_keeps_existing_cache(self):
        self.assertEqual(self.run_bootstrap("help").returncode, 0)
        target = self.cache / REVISION
        (target / "ui.html").write_bytes(b"previous contents")
        self.failed_name = "cloud-network.py"
        self.assertNotEqual(self.run_bootstrap("help").returncode, 0)
        self.assertEqual((target / "ui.html").read_bytes(), b"previous contents")
        self.assertEqual((target / "launcher.sh").read_bytes(), self.files["launcher.sh"])

    def test_arguments_are_forwarded_literally(self):
        stub = b'#!/bin/bash\nprintf "%s\\0" "$@"\n'
        (self.sources / "launcher.sh").write_bytes(stub)
        self.payloads["launcher.sh"] = stub
        self.prepare()
        args = ["start", "with spaces", "literal$(false)", 'a"b', "a'b", ""]
        result = self.run_bootstrap(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"".join(arg.encode() + b"\0" for arg in args))

    def test_concurrent_bootstraps_install_once(self):
        env = os.environ | {"CLOUDXR_LAUNCHER_CACHE": str(self.cache)}
        processes = [subprocess.Popen([self.artifact, "help"], env=env, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE) for _ in range(3)]
        try:
            for process in processes:
                _, error = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, error)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
        self.assertCountEqual(self.requests, BUILD.NAMES)

    def test_different_revision_does_not_overwrite_previous_install(self):
        self.assertEqual(self.run_bootstrap("help").returncode, 0)
        other = "f" * 40
        self.prepare(other)
        self.assertEqual(self.run_bootstrap("help").returncode, 0)
        self.assertTrue((self.cache / REVISION / "launcher.sh").exists())
        self.assertTrue((self.cache / other / "launcher.sh").exists())
