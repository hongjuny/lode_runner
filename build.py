#!/usr/bin/env python3
"""Build Lode Runner for the Apple II from the literate source.

Tangles `main.nw` into assembly, reorders the code by ORG address, assembles
it with `dasm` to produce `main.bin`, and reconstructs the original disk
image as `lode_runner.do`.

Steps:
    1. Tangle main.nw -> main.asm (via weave.py, expanding the <<*>> root chunk)
    2. Reorder the assembly so ORG addresses are non-decreasing
    3. Assemble main.asm -> main.bin with dasm
    4. Reconstruct lode_runner.do from main.bin and the disk/track_*.asm data
    5. (optional) compare main.bin against golden_source.bin and
       lode_runner.do against the archive.org original

The reorder step exists because `dasm` does not handle code blocks whose ORG
locations jump around; grouping them by ascending ORG address fixes that.

Usage:
    python build.py                     # tangle, reorder, assemble, build disk
    python build.py --verify            # also diff against golden references
    python build.py --dasm PATH         # path to the dasm executable
    python build.py --no-weave          # skip regenerating main.tex
"""
from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys

import weave

PROJECT_ROOT = pathlib.Path(__file__).parent

NWFILE = PROJECT_ROOT / "main.nw"
TEXFILE = PROJECT_ROOT / "main.tex"
RAW_ASM = PROJECT_ROOT / "main2.asm"  # tangled, before reordering (gitignored)
ASMFILE = PROJECT_ROOT / "main.asm"          # reordered, fed to dasm
BINFILE = PROJECT_ROOT / "main.bin"
GOLDEN = PROJECT_ROOT / "golden_source.bin"
DISK_DIR = PROJECT_ROOT / "disk"             # non-program sector data
DSKFILE = PROJECT_ROOT / "lode_runner.do"
ORIG_DSK = PROJECT_ROOT / "Lode_Runner_1983_Broderbund_cr_Reset_Vector.do"

ORG_RE = re.compile(r"^ +ORG +(\$?[0-9A-Fa-f]+) *$")
SECTOR_RE = re.compile(r"^; Track \$([0-9A-Fa-f]+), sector \$([0-9A-Fa-f]+)")

# .do image geometry
SECTOR_SIZE = 256
SECTORS_PER_TRACK = 16
TRACK_SIZE = SECTOR_SIZE * SECTORS_PER_TRACK
NUM_TRACKS = 35
DISK_SIZE = NUM_TRACKS * TRACK_SIZE

# The game lives on the disk as an ordinary DOS 3.3 binary (B) file,
# BSAVEd with address $0800 and length $8100.  Its data sectors follow
# DOS 3.3's descending-sector allocation starting right after the first
# track/sector list at T$12,S$F.  The first T/S list holds 122 entries;
# DOS then allocated T$19,S$4 for the second T/S list, so the data
# sectors skip it.
TSLIST1 = (0x12, 0x0F)
TSLIST2 = (0x19, 0x04)
FILE_LOAD_ADDR = 0x0800
TSLIST1_ENTRIES = 122


def reorder_by_org(in_lines: list[str]) -> list[str]:
    """Groups lines by their ORG address and emits them in ascending order.

    Lines before the first ORG go in a special group that is emitted first with
    no ORG directive.  This mirrors the old reorder_asm.py.
    """
    chunks: dict[int, list[str]] = {-1: [], 0: []}
    org = -1
    for line in in_lines:
        m = ORG_RE.match(line)
        if m:
            addr = m.group(1)
            org = int(addr[1:], 16) if addr.startswith("$") else int(addr, 10)
            chunks.setdefault(org, [])
            continue
        chunks[org].append(line)

    # If nothing was placed at ORG 0, add a DS 1 so the ROM output starts at 0.
    if not chunks[0]:
        chunks[0].append("    DS 1")

    out: list[str] = []
    for addr, lines in sorted(chunks.items()):
        if addr != -1:
            out.append(f"    ORG    ${addr:04X}")
        out.extend(lines)
    return out


def tangle_and_reorder(weave_tex: bool) -> None:
    print("Tangling main.nw...")
    weaver = weave.Weaver()
    weaver.run(
        str(NWFILE),
        texpath=TEXFILE if weave_tex else None,
        tanglepath=RAW_ASM,
        root="*",
    )
    print("Reordering by ORG...")
    raw = RAW_ASM.read_text().splitlines()
    reordered = reorder_by_org(raw)
    ASMFILE.write_text("\n".join(reordered) + "\n", newline="\n")


def assemble(dasm: str) -> bool:
    print(f"Assembling {ASMFILE.name} with dasm...")
    result = subprocess.run(
        [dasm, str(ASMFILE), "-f3", f"-o{BINFILE}"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.stdout.write(result.stderr)
        return False
    print(f"  OK ({BINFILE.stat().st_size} bytes)")
    return True


def load_image() -> bytes:
    """Returns the game as it sits on disk: memory $3F00-$BFFF.

    The boot loader loads the file to $3F00-$BFFF and then moves
    $3F00-$5EFF down to $0000-$1FFF, so the on-disk image is main.bin's
    $0000-$1FFF followed by its $5F00-$BFFF.
    """
    mem = BINFILE.read_bytes()
    return mem[:0x2000] + mem[0x5F00:0xC000]


def write_sector(dsk: bytearray, track: int, sector: int, data: bytes) -> None:
    offset = track * TRACK_SIZE + sector * SECTOR_SIZE
    dsk[offset:offset + len(data)] = data


def program_data_chain() -> list[tuple[int, int]]:
    """The game file's data sectors in file order.

    DOS 3.3 allocates data sectors within a track in descending order:
    T$12 S$E..0 (S$F is the first T/S list), T$13-$18 S$F..0, T$19
    S$F..5 and S$3..0 (S$4 is the second T/S list), then T$1A S$F..C.
    """
    chain = [(0x12, s) for s in range(0x0E, -1, -1)]
    for t in range(0x13, 0x19):
        chain += [(t, s) for s in range(0x0F, -1, -1)]
    chain += [(0x19, s) for s in range(0x0F, 0x04, -1)]
    chain += [(0x19, s) for s in range(0x03, -1, -1)]
    chain += [(0x1A, s) for s in range(0x0F, 0x0B, -1)]
    return chain


def read_track_asm(path: pathlib.Path) -> list[tuple[int, int, bytes]]:
    """Parses a disk/track_XX.asm file into (track, sector, data) tuples."""
    sectors: list[tuple[int, int, bytes]] = []
    track = sector = None
    data = bytearray()

    def flush() -> None:
        if track is not None and data:
            padded = (bytes(data) + bytes(SECTOR_SIZE))[:SECTOR_SIZE]
            sectors.append((track, sector, padded))

    for line in path.read_text().splitlines():
        m = SECTOR_RE.match(line)
        if m:
            flush()
            track, sector = int(m.group(1), 16), int(m.group(2), 16)
            data = bytearray()
        elif line.strip().startswith("HEX"):
            data.extend(bytes.fromhex(line.strip()[3:].replace(" ", "")))
    flush()
    return sectors


def build_disk() -> None:
    """Reconstructs the original .do disk image from main.bin.

    Sectors not covered by disk/track_*.asm or the game file are zero.
    """
    print(f"Building {DSKFILE.name}...")
    dsk = bytearray(DISK_SIZE)

    # Boot loader, level, and catalog tracks kept as data.
    for path in sorted(DISK_DIR.glob("track_*.asm")):
        for track, sector, data in read_track_asm(path):
            write_sector(dsk, track, sector, data)

    # The game itself: a DOS 3.3 B file (BSAVEd A$0800,L$8100).  The
    # last data sector's slack bytes are whatever DOS's write buffer
    # held, which on the original disk is a stale copy of the file's
    # second sector shifted by one byte: $FE then image bytes 1-$FB.
    img = load_image()
    header = FILE_LOAD_ADDR.to_bytes(2, "little") + len(img).to_bytes(2, "little")
    stream = header + img + b"\xFE" + img[1:0xFC]
    chain = program_data_chain()
    assert len(stream) == len(chain) * SECTOR_SIZE
    for i, (track, sector) in enumerate(chain):
        write_sector(dsk, track, sector,
                     stream[i * SECTOR_SIZE:(i + 1) * SECTOR_SIZE])

    # Track/sector lists (standard DOS 3.3 format: next list's track and
    # sector at +$01/+$02, this list's first-entry file offset at +$05,
    # track/sector pairs from +$0C).
    ts1 = bytearray(SECTOR_SIZE)
    ts1[1], ts1[2] = TSLIST2
    for i, (track, sector) in enumerate(chain[:TSLIST1_ENTRIES]):
        ts1[0x0C + 2 * i] = track
        ts1[0x0D + 2 * i] = sector
    write_sector(dsk, *TSLIST1, ts1)

    ts2 = bytearray(SECTOR_SIZE)
    ts2[5] = TSLIST1_ENTRIES
    for i, (track, sector) in enumerate(chain[TSLIST1_ENTRIES:]):
        ts2[0x0C + 2 * i] = track
        ts2[0x0D + 2 * i] = sector
    write_sector(dsk, *TSLIST2, ts2)

    DSKFILE.write_bytes(dsk)
    print(f"  OK ({len(dsk)} bytes)")


def verify_disk() -> int:
    """Compares lode_runner.do against the archive.org original."""
    if not ORIG_DSK.exists():
        print(f"  {ORIG_DSK.name} not found; skipping disk verification.")
        print("  Download it from https://archive.org/download/"
              "a2_Lode_Runner_1983_Broderbund_cr_Reset_Vector/"
              + ORIG_DSK.name)
        return -1
    orig = ORIG_DSK.read_bytes()
    built = DSKFILE.read_bytes()
    diffs = 0
    for track in range(NUM_TRACKS):
        for sector in range(SECTORS_PER_TRACK):
            offset = track * TRACK_SIZE + sector * SECTOR_SIZE
            n = sum(built[offset + i] != orig[offset + i]
                    for i in range(SECTOR_SIZE))
            if n:
                print(f"  track ${track:02X} sector ${sector:X}: "
                      f"{n} byte diffs")
                diffs += n
    if len(built) != len(orig):
        print(f"  size mismatch: {len(built)} vs {len(orig)}")
        diffs += abs(len(built) - len(orig))
    if diffs == 0:
        print(f"  {DSKFILE.name} matches {ORIG_DSK.name}.")
    return diffs


def verify() -> int:
    """Compares main.bin against golden_source.bin the way diff.py does.

    The loader copies data to $3F00 then moves $3F00-$5EFF to $0000-$1FFF, so
    the golden image and the assembled binary are compared in two segments:
    $0000-$1FFF and $5F00-onwards.
    """
    if not GOLDEN.exists():
        print(f"  golden_source.bin not found ({GOLDEN})")
        return -1
    golden = GOLDEN.read_bytes()
    target = BINFILE.read_bytes()
    print(f"  golden_source.bin: {len(golden)} bytes; main.bin: {len(target)} bytes")

    segments = [
        ("segment 1 (0000-1FFF)", golden[:0x2000], target[:0x2000], 0x0000),
        ("segment 2 (5F00-)", golden[0x2000:], target[0x5F00:], 0x5F00),
    ]
    diffs = 0
    for label, g, t, base in segments:
        seg_diff = 0
        for i in range(min(len(g), len(t))):
            if g[i] != t[i]:
                if seg_diff == 0:
                    print(f"  {label}: first diff at {base + i:04X} "
                          f"(golden {g[i]:02X} vs main {t[i]:02X})")
                seg_diff += 1
        if len(g) != len(t):
            seg_diff += abs(len(g) - len(t))
        if seg_diff == 0:
            print(f"  {label}: match")
        diffs += seg_diff
    return diffs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--verify", action="store_true",
                        help="compare main.bin against golden_source.bin and "
                             "lode_runner.do against the original disk image")
    parser.add_argument("--no-weave", action="store_true",
                        help="do not regenerate main.tex")
    parser.add_argument("--dasm", default=None,
                        help="path to the dasm executable (default: search PATH)")
    args = parser.parse_args()

    dasm = args.dasm or shutil.which("dasm")
    if not dasm:
        print("dasm not found on PATH; pass --dasm PATH to locate it.")
        sys.exit(1)

    tangle_and_reorder(weave_tex=not args.no_weave)

    if not assemble(dasm):
        print("Assembly failed.")
        sys.exit(1)

    build_disk()

    if args.verify:
        print("Verifying against golden_source.bin...")
        d = verify()
        if d == 0:
            print("\nmain.bin matches golden_source.bin.")
        elif d > 0:
            print(f"\n{d} differing bytes.")
            sys.exit(1)
        print("Verifying against the original disk image...")
        d = verify_disk()
        if d > 0:
            print(f"\n{d} differing bytes in the disk image.")
            sys.exit(1)

    print("\nBuild complete.")


if __name__ == "__main__":
    main()
