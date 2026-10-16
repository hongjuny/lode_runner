#!/usr/bin/env python3
"""Export the 150 original level sectors in track/sector order for SwiftPM."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from capture_reference import REFERENCE, ROOT, read_sectors

OUTPUT = ROOT / "Sources" / "LodeRunnerCore" / "Resources" / "levels.bin"


def payload() -> bytes:
    sectors = read_sectors()
    reference = json.loads(REFERENCE.read_text())
    output = bytearray()
    for index, entry in enumerate(reference["levels"]):
        address = (3 + index // 16, index % 16)
        sector = sectors[address]
        if entry["level"] != index + 1 or (entry["track"], entry["sector"]) != address:
            raise ValueError(f"reference ordering mismatch at level {index + 1}")
        if hashlib.sha256(sector).hexdigest() != entry["sha256"]:
            raise ValueError(f"reference hash mismatch at level {index + 1}")
        output.extend(sector)
    if len(output) != 150 * 256:
        raise ValueError("expected exactly 150 sectors")
    return bytes(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = payload()
    if args.write:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_bytes(expected)
        print(f"Wrote {OUTPUT.relative_to(ROOT)} ({len(expected)} bytes)")
    elif not OUTPUT.exists() or OUTPUT.read_bytes() != expected:
        raise SystemExit(f"{OUTPUT.relative_to(ROOT)} differs; run --write")
    else:
        print("150 bundled level sectors match the source and reference hashes")


if __name__ == "__main__":
    main()
