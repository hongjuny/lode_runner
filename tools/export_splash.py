#!/usr/bin/env python3
"""Expand the 192-row splash HGR stream at $0F00 in main.bin."""
from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "apple2" / "main.bin"
DESTINATION = ROOT / "Sources/LodeRunnerCore/Resources/splash.bin"


def expand(data: bytes) -> bytes:
    cursor = 0x0F00
    page = bytearray(40 * 192)
    for row in range(192):
        column = 0
        while True:
            value = data[cursor]
            cursor += 1
            if value == 0:
                break
            if value < 0x80:
                column = value
            else:
                if column >= 40:
                    raise ValueError(f"splash row {row} exceeds 40 bytes")
                page[row * 40 + column] = value
                column += 1
    return bytes(page)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = expand(SOURCE.read_bytes())
    if args.write:
        DESTINATION.write_bytes(result)
        print(f"Wrote {DESTINATION} ({len(result)} bytes)")
    else:
        if not DESTINATION.exists() or DESTINATION.read_bytes() != result:
            raise SystemExit("Bundled splash page differs from main.bin")
        print("Bundled splash page matches main.bin")


if __name__ == "__main__":
    main()
