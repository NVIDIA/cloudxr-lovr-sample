#!/usr/bin/env python3
"""Build a static UI preview backed by the browser-side mock API."""

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/ui.html"
MOCK = ROOT / "preview/mock.js"


def build() -> str:
    page = SOURCE.read_text()
    marker = "<script>"
    if page.count(marker) != 1:
        raise ValueError("src/ui.html must contain exactly one inline script")
    return page.replace(marker, '<script src="mock.js"></script>\n<script>', 1)


def main() -> int:
    destination = Path(sys.argv[1] if len(sys.argv) > 1 else "public/index.html")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(build())
    (destination.parent / "mock.js").write_bytes(MOCK.read_bytes())
    print(f"Preview written to {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
