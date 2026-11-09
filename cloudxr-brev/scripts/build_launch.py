#!/usr/bin/env python3
"""Build a small, revision-pinned Brev bootstrap from published GitHub sources."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "launch.sh"
LIMIT = 16 * 1024
REPOSITORY = "NVIDIA/cloudxr-lovr-sample"
SOURCE_PATH = "cloudxr-brev/src"
NAMES = ("launcher.sh", "ui.html", "cloud-network.py", "cloud-runtime.lua")
SOURCES = tuple(ROOT / "src" / name for name in NAMES)


def source_manifest() -> dict[str, tuple[str, int]]:
    result = {}
    for source in SOURCES:
        data = source.read_bytes()
        result[source.name] = (hashlib.sha256(data).hexdigest(), len(data))
    return result


def source_url(revision: str, repository: str = REPOSITORY, source_path: str = SOURCE_PATH) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be a full, lowercase 40-character Git commit SHA")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or any(
        part in {".", ".."} for part in repository.split("/")
    ):
        raise ValueError("repository must be a GitHub owner/repository")
    path = PurePosixPath(source_path)
    if not re.fullmatch(r"[A-Za-z0-9_./-]+", source_path) or path.is_absolute() or ".." in path.parts:
        raise ValueError("source path must be a relative repository directory")
    if source_path in {"", "."}:
        raise ValueError("source path must name a directory")
    return f"https://raw.githubusercontent.com/{repository}/{revision}/{path}"


def verify_published(base: str, manifest: dict[str, tuple[str, int]]) -> None:
    """Do not release a bootstrap pointing at unpublished or different files."""
    for name, (digest, size) in manifest.items():
        with urllib.request.urlopen(f"{base}/{name}", timeout=30) as response:
            if not response.geturl().startswith("https://"):
                raise ValueError("source download redirected away from HTTPS")
            data = response.read(size + 1)
        if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"published {name} differs from src/{name}; check out the pinned revision")


def build(revision: str, repository: str = REPOSITORY, source_path: str = SOURCE_PATH,
          *, manifest: dict[str, tuple[str, int]] | None = None) -> bytes:
    base = source_url(revision, repository, source_path)
    manifest = json.dumps(source_manifest() if manifest is None else manifest, separators=(",", ":"))
    # Kept as readable Python: only this bootstrap counts toward Brev's limit.
    program = r'''#!/bin/bash
set -eu
umask 077
exec python3 - "$@" <<'PY'
import fcntl, hashlib, json, os, pathlib, shutil, sys, tempfile, time
import urllib.error, urllib.request

revision = @REVISION@
base = @BASE@
manifest = json.loads(@MANIFEST@)
root = pathlib.Path(os.environ.get('CLOUDXR_LAUNCHER_CACHE') or pathlib.Path.home() / '.cache/cxr-launcher')
target = root / revision

def valid(directory):
    if directory.is_symlink() or not directory.is_dir():
        return False
    try:
        for name, (digest, size) in manifest.items():
            file = directory / name
            if file.is_symlink() or file.stat().st_size != size:
                return False
            if hashlib.sha256(file.read_bytes()).hexdigest() != digest:
                return False
        return os.access(directory / 'launcher.sh', os.X_OK)
    except OSError:
        return False

def download(name, digest, size):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(base + '/' + name, timeout=30) as response:
                if not response.geturl().startswith('https://'):
                    raise ValueError('download redirected away from HTTPS')
                data = response.read(size + 1)
            if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
                raise ValueError('checksum mismatch: ' + name)
            return data
        except OSError as exc:
            if attempt == 2 or isinstance(exc, urllib.error.HTTPError) and exc.code < 500:
                raise
            time.sleep(attempt + 1)

def install():
    root.mkdir(parents=True, exist_ok=True)
    with (root / ('.' + revision + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if valid(target):
            return
        stage = pathlib.Path(tempfile.mkdtemp(prefix='.' + revision + '.', dir=root))
        previous = None
        promoted = False
        try:
            for name, (digest, size) in manifest.items():
                file = stage / name
                file.write_bytes(download(name, digest, size))
                file.chmod(0o700 if name == 'launcher.sh' else 0o600)
            if not valid(stage):
                raise ValueError('incomplete launcher download')
            if target.exists() or target.is_symlink():
                previous = pathlib.Path(tempfile.mkdtemp(prefix='.old-' + revision + '.', dir=root))
                previous.rmdir()
                target.rename(previous)
            try:
                stage.rename(target)
                promoted = True
            except OSError:
                if previous is not None:
                    previous.rename(target)
                    previous = None
                raise
        finally:
            shutil.rmtree(stage, ignore_errors=True)
            if previous is not None and promoted:
                if previous.is_symlink() or previous.is_file():
                    previous.unlink()
                else:
                    shutil.rmtree(previous)

try:
    install()
except (OSError, ValueError) as exc:
    print('CloudXR launcher installation failed: ' + str(exc), file=sys.stderr)
    raise SystemExit(1)
os.execv(str(target / 'launcher.sh'), [str(target / 'launcher.sh'), *sys.argv[1:]])
PY
'''
    return (program.replace("@REVISION@", repr(revision))
            .replace("@BASE@", repr(base))
            .replace("@MANIFEST@", repr(manifest))).encode()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default=os.environ.get("CLOUDXR_LAUNCHER_REVISION"),
                        help="full published GitHub commit SHA (or CLOUDXR_LAUNCHER_REVISION)")
    parser.add_argument("--repository", default=REPOSITORY)
    parser.add_argument("--source-path", default=SOURCE_PATH)
    args = parser.parse_args(argv)
    if not args.revision:
        parser.error("--revision is required; publish cloudxr-brev/ to GitHub first")
    try:
        manifest = source_manifest()
        artifact = build(args.revision, args.repository, args.source_path, manifest=manifest)
        if len(artifact) > LIMIT:
            raise ValueError(f"launch.sh is {len(artifact)} bytes; Brev limit is {LIMIT}")
        verify_published(source_url(args.revision, args.repository, args.source_path), manifest)
    except (OSError, ValueError) as exc:
        print(f"Build failed: {exc}", file=sys.stderr)
        return 1
    OUTPUT.write_bytes(artifact)
    OUTPUT.chmod(0o755)
    checksum = hashlib.sha256(artifact).hexdigest()
    OUTPUT.with_suffix(".sh.sha256").write_text(f"{checksum}  launch.sh\n")
    print(f"launch.sh: {len(artifact)} / {LIMIT} bytes; pinned to {args.revision}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
