#!/usr/bin/env python3
"""Extract port-relevant game state from a Bobbin save-ram dump."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def board_rows(ram: bytes, base: int) -> list[str]:
    return ["".join(f"{value:X}" for value in ram[base + 28 * row : base + 28 * (row + 1)])
            for row in range(16)]


def extract(ram: bytes, label: str, breakpoint: str) -> dict[str, object]:
    if len(ram) != 0x20000:
        raise ValueError(f"expected Bobbin's 128 KiB dump, got {len(ram)} bytes")

    guard_count = ram[0x8D]
    guards = [
        {
            "column": ram[0x0C60 + i],
            "row": ram[0x0C68 + i],
            "x_offset": ram[0x0C78 + i],
            "y_offset": ram[0x0C80 + i],
            "gold_timer": ram[0x0C70 + i],
            "resurrection_timer": ram[0x0C98 + i],
        }
        for i in range(1, guard_count + 1)
    ]
    holes = [
        {"slot": i, "column": ram[0x0CA0 + i], "row": ram[0x0CC0 + i],
         "remaining": ram[0x0CE0 + i]}
        for i in range(31) if ram[0x0CE0 + i] != 0
    ]
    return {
        "label": label,
        "capture_pc": breakpoint,
        "ram_sha256": hashlib.sha256(ram).hexdigest(),
        "game_mode": ram[0xA7],
        "level": ram[0xA6],
        "disk_level_index": ram[0x96],
        "lives": ram[0x98],
        "alive": ram[0x9A],
        "score_bcd_bytes": ram[0x8E:0x92].hex(),
        "gold_remaining": ram[0x93],
        "ladder_count": ram[0xA3],
        "frame_period": ram[0x8C],
        "input_mode": ram[0x95],
        "key_command": ram[0x9E],
        "key_command_lr": ram[0x9F],
        "player": {
            "column": ram[0], "row": ram[1],
            "x_offset": ram[2], "y_offset": ram[3],
            "animation": ram[4], "facing": ram[5],
        },
        "dig": {"direction": ram[0x9C], "animation": ram[0xA0]},
        "guards": guards,
        "guard_phase": ram[0x64],
        "holes": holes,
        "active_board_sha256": hashlib.sha256(ram[0x0800:0x09C0]).hexdigest(),
        "background_board_sha256": hashlib.sha256(ram[0x0A00:0x0BC0]).hexdigest(),
        "active_board": board_rows(ram, 0x0800),
        "background_board": board_rows(ram, 0x0A00),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ram_dump", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--label", required=True)
    parser.add_argument("--pc", required=True, help="PC at the capture point, e.g. 60E4")
    args = parser.parse_args()

    snapshot = extract(args.ram_dump.read_bytes(), args.label, args.pc.upper())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(snapshot, indent=2) + "\n")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
