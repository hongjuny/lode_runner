#!/usr/bin/env python3
"""Bundle the original 104 x 11 x 2 sprite bytes for the macOS renderer."""

from __future__ import annotations

import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Sources/LodeRunnerCore/Resources/sprites.bin"


def payload() -> bytes:
    source = (ROOT / "apple2" / "sprite_data.asm").read_text()
    chunks = re.findall(r"^\s*HEX\s+([0-9A-Fa-f ]+)\s*$", source, re.MULTILINE)
    data = b"".join(bytes.fromhex(chunk) for chunk in chunks)
    if len(data) != 104 * 11 * 2:
        raise ValueError(f"expected 2288 sprite bytes, got {len(data)}")
    return data


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--write", action="store_true")
    modes.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = payload()
    if args.write:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_bytes(expected)
        print(f"Wrote {OUTPUT.relative_to(ROOT)} ({len(expected)} bytes)")
    elif not OUTPUT.exists() or OUTPUT.read_bytes() != expected:
        raise SystemExit(f"{OUTPUT.relative_to(ROOT)} differs; run --write")
    else:
        print("Bundled sprites match sprite_data.asm")


if __name__ == "__main__":
    main()
