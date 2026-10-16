#!/usr/bin/env python3
"""Freeze the original binary and level-sector data as a reference manifest.

This captures static disk data. It does not claim to be a 6502 execution trace.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
APPLE2 = ROOT / "apple2"
REFERENCE = ROOT / "fixtures" / "reference_levels.json"
SECTOR_HEADER = re.compile(r"^; Track \$([0-9A-Fa-f]+), sector \$([0-9A-Fa-f]+)")
HEX_LINE = re.compile(r"^\s*HEX\s+([0-9A-Fa-f ]+)\s*$")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_sectors() -> dict[tuple[int, int], bytes]:
    sectors: dict[tuple[int, int], bytes] = {}
    for track in range(3, 13):
        path = APPLE2 / "disk" / f"track_{track:02x}.asm"
        address: tuple[int, int] | None = None
        payload = bytearray()

        def finish() -> None:
            if address is None:
                return
            if len(payload) != 256:
                raise ValueError(f"track/sector {address} has {len(payload)} bytes, expected 256")
            if address in sectors:
                raise ValueError(f"duplicate track/sector {address}")
            sectors[address] = bytes(payload)

        for line in path.read_text().splitlines():
            header = SECTOR_HEADER.match(line)
            if header:
                finish()
                address = (int(header[1], 16), int(header[2], 16))
                payload = bytearray()
                continue
            hex_line = HEX_LINE.match(line)
            if hex_line:
                if address is None:
                    raise ValueError(f"HEX before sector header in {path}")
                payload.extend(bytes.fromhex(hex_line[1]))
        finish()
    return sectors


def decode_level(data: bytes) -> list[list[int]]:
    if len(data) != 256:
        raise ValueError("level sector must be 256 bytes")
    board = []
    for row in range(16):
        cells = []
        for pair in data[row * 14 : (row + 1) * 14]:
            cells.extend((pair & 0x0F, pair >> 4))
        board.append(cells)
    return board


def summarize_level(index: int, data: bytes) -> dict[str, object]:
    board = decode_level(data)
    positions = lambda tile: [[r, c] for r, row in enumerate(board) for c, value in enumerate(row) if value == tile]
    counts = Counter(value for row in board for value in row)
    if any(value > 9 for value in counts):
        raise ValueError(f"level {index + 1} uses undefined tile values")
    return {
        "level": index + 1,
        "track": 3 + index // 16,
        "sector": index % 16,
        "sha256": digest(data),
        "player": positions(9),
        "guards": positions(8),
        "gold": len(positions(7)),
        "tile_counts": [counts.get(tile, 0) for tile in range(10)],
    }


def make_manifest() -> dict[str, object]:
    main = (APPLE2 / "main.bin").read_bytes()
    golden = (APPLE2 / "golden_source.bin").read_bytes()
    loaded = main[:0x2000] + main[0x5F00:0xC000]
    if len(main) != 0xC000 or len(golden) != 0x8100 or loaded != golden:
        raise ValueError("committed main.bin does not match golden_source.bin")

    sectors = read_sectors()
    levels = []
    for index in range(150):
        address = (3 + index // 16, index % 16)
        if address not in sectors:
            raise ValueError(f"missing level sector {address}")
        levels.append(sectors[address])

    return {
        "schema_version": 1,
        "kind": "static_disk_reference",
        "binary": {
            "main_size": len(main),
            "main_sha256": digest(main),
            "golden_size": len(golden),
            "golden_sha256": digest(golden),
            "loaded_image_matches_golden": True,
        },
        "levels_size": sum(map(len, levels)),
        "levels_sha256": digest(b"".join(levels)),
        "levels": [summarize_level(i, data) for i, data in enumerate(levels)],
        "level_1_rows": ["".join(str(cell) for cell in row) for row in decode_level(levels[0])],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="write the reference manifest")
    mode.add_argument("--check", action="store_true", help="compare source data to the manifest")
    args = parser.parse_args()

    current = json.dumps(make_manifest(), indent=2, ensure_ascii=False) + "\n"
    if args.write:
        REFERENCE.parent.mkdir(parents=True, exist_ok=True)
        REFERENCE.write_text(current)
        print(f"Wrote {REFERENCE.relative_to(ROOT)}")
    else:
        if not REFERENCE.exists() or REFERENCE.read_text() != current:
            raise SystemExit("Reference differs; inspect source changes before updating the manifest")
        print("Reference manifest matches the committed binary and all 150 level sectors")


if __name__ == "__main__":
    main()
