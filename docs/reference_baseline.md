# Original execution baseline

The baseline has two kinds of evidence:

1. `fixtures/reference_levels.json` contains **static data** derived from `apple2/main.bin`, `apple2/golden_source.bin`, and all 150 level sectors. Verify it with `python3 tools/capture_reference.py --check`.
2. `fixtures/runtime/*.json` contains **runtime memory states** captured while running the reconstructed disk image in an Apple II emulator. These snapshots support comparisons of 6502 state transitions.

`tools/extract_runtime_snapshot.py` reads the addresses needed for gameplay rules from a 128 KiB emulator RAM dump. Snapshots do not contain HGR pixels, CPU registers, or a complete disk I/O trace. `capture_pc` is the program counter at the pause point; board and guard values are the contents at that instant.

## Source and execution environment

- Committed `apple2/main.bin` SHA-256: `5c9cc551242e08b76cb3a37e89f8bfb6dc02d886b628aab07798833b8708bbb1`
- `apple2/golden_source.bin` SHA-256: `a2e62f89abc8ae6aa763574fbf4db2b38cf7eb3f5b4fc0b68cbf339a12f9bd90`. The 33,024-byte disk-loaded portion of `main.bin` matches it.
- Reconstructed disk image SHA-256: `22b3b578e254c781fd456fbbf7c22124e970997f328cd83b89ca29a1219c871e`
- Emulator: [Bobbin](https://github.com/benj-edwards/bobbin-ai), commit `b5ca8d3a957132640c94dd00ad6c3d058a49125a`, Apple II+ (`--machine plus`), simple interface.
- That Bobbin commit omits `control_socket.c` from `bobbin_SOURCES` in `src/Makefile.am`. It was added only in a temporary build directory; no source or binary in this repository was changed for that workaround.

The disk image was built from the committed binaries without an assembler, from inside `apple2/`:

```sh
cd apple2
python3 -c 'import build, pathlib; build.DSKFILE=pathlib.Path("/tmp/lode_runner_reference.do"); build.build_disk()'
```

Emulator command, from the Bobbin build directory:

```sh
./bobbin --simple --machine plus --disk /tmp/lode_runner_reference.do \
  --breakpoint 60E4 --max-runtime 300
```

`$60E4` is the start of the game loop immediately before `MOVE_PLAYER`. In the debugger, `save-ram /tmp/name.ram` resumes execution after saving, so stop at the breakpoint again before taking another snapshot. Convert a dump to JSON with:

```sh
python3 tools/extract_runtime_snapshot.py /tmp/name.ram \
  fixtures/runtime/name.json --label name --pc 60E4
```

Run that conversion command from the port repository root.

## Captured states

| File | Observed state | Capture point |
| --- | --- | --- |
| `level1_start.json` | Level 1 starts with player at column 14, row 14, offsets 2/2; 6 gold, 3 guards, 5 lives | `$60E4` |
| `level1_left_once.json` | One keyboard `J`: player remains in column 14; horizontal offset changes 2 → 1 | `$60E4` |
| `level1_gold_pickup.json` | Repeated `L`: gold count 6 → 5, BCD score `00000000` → `50020000` (+250), player reaches column 17 | `$60E4` |
| `level1_hole_open.json` | `U` from the starting state: active-board brick at column 13, row 15 changes 1 → 0; background stays 1; fill timer is 179 | `$60E4` |
| `level1_fall_into_hole.json` | Repeated `J` after digging: player at column 13, row 15, vertical offset 0, still alive | `$656F`, immediately after changing the player row |
| `level1_death.json` | Along the same hole route, `ALIVE` changes 1 → 0; player at column 13, row 15; fill timer is 1 | `$6E02`, immediately after death detection |

For `level1_left_once`, `level1_hole_open`, and `level1_fall_into_hole`, the debugger set `$95` (`INPUT_MODE`) to `$CB` for keyboard input. The original controls can also select this mode. This intervention is recorded because the initial snapshot uses `$CA` (joystick mode). The gold scenario queued 20 `L` inputs and watched `$93` (`GOLD_COUNT`). Digging watched `$09B1` (active board, row 15, column 13); falling watched `$01` (`PLAYER_ROW`); death watched `$9A` (`ALIVE`).

The final death snapshot captures the instant `ALIVE` changes. It does not establish the exact cause of death or the later life decrement and restart. Those behaviors require snapshots at subsequent loop boundaries.

## Comparing the port

Export `GameState` at level start and after each matching input sequence, then compare `player`, `guards`, `holes`, `gold_remaining`, `score_bcd_bytes`, `active_board`, and `background_board`. `ram_sha256` identifies the original dump and is not a value to compare with native output. Match the number of inputs and the capture point before comparing `guard_phase` or detailed guard state.
