# macOS porting plan

The reference material is [`main_logic_io_map.md`](main_logic_io_map.md), `apple2/main.nw`, `apple2/main.bin`, `apple2/golden_source.bin`, and `apple2/disk/track_*.asm`. The goal is to preserve game rules, level data, and input response while placing display, audio, and persistence behind native boundaries.

## Progress and evidence

The [execution baseline](reference_baseline.md) contains static data for all 150 levels and six captured level-one runtime states. The Swift level decoder, player engine, outer game loop, guard engine, and AppKit app are implemented. The app uses the original title, sprites, and status glyphs. After level 150 it returns to the first disk level and increases the guard pattern offset, following the original loader's missing-player-sector path.

All 150 sectors pass round-trip encoding tests. The first level's initial active and background boards match the captured 6502 state. Levels 8, 80, and 113 contain six guard tiles; the original loader keeps only the first five found in reverse scan order and clears the sixth. The Swift loader and tests preserve that limit. Running Swift tests with `--scratch-path /tmp/lode-runner-swift-build` avoids possible signing failures for test bundles in a OneDrive working directory.

`PlayerEngine.step` corresponds to one `MOVE_PLAYER` call: continue digging, fall automatically, try vertical or dig input, then try horizontal input. It preserves within-cell offset crossings and +250 points for gold. A dug hole starts at 180 and `HANDLE_TIMERS` reduces it to 179 during the same outer step. Captured states have been compared for one left step, gold pickup, left digging, and falling.

`GameState.advance` executes the player step, bitmap overlap collision, exit ladder reveal when no gold remains, top-row completion, hole and resurrection timers, and guard movement. A filled brick can kill the player or start a guard's resurrection. Completing a level increments level and lives and adds 1,500 points. The macOS session controller handles restart after death and loading the next level.

`GuardEngine` cycles the original three-byte movement pattern and one-based guard numbers. It evaluates candidate routes using floor support, ladders, and ropes and updates both boards at cell boundaries. Guard gold pickup starts a variable timer derived from `$53` (`GUARD_RESURRECT_COL`), rather than a constant. The first level's first move and 13-step digging capture agree on guard positions, offsets, gold timers, and boards. The `$656F` falling capture is from the middle of a 6502 move before the new active-board sprite is written, so that one cell differs from a completed Swift step. Long guard paths on other levels still need comparison.

The app renders the 104 sprites from `apple2/sprite_data.asm` and expands the title HGR stream at `$0F00` in `apple2/main.bin`. It draws a 280×192 bitmap with original status glyphs and computes blue, orange, and white from neighboring bits and byte phase. Input uses physical key positions for `U` and `O`, including with non-Latin input methods; short taps are queued until the next game step. Bitmap overlap between player and guards is checked when the player is drawn. Gold pickup follows the original `DIDNT_PICK_UP_GOLD` exception. This is narrower than the original comparison of entire HGR pages.

The display is rebuilt from logical state each step rather than replaying the original HGR writes and page flips. RGB values and sound cues are approximations. At 1× the game runs at an estimated 24 steps per second, informed by `FRAME_PERIOD=6`; it has not been calibrated to real Apple II+ cycles. `⌘1`–`⌘4` selects one to four times that rate. Hardware-perfect HGR writes and speaker timing are outside the current gameplay validation goal.

## Architecture choices

| Concern | Porting rule |
| --- | --- |
| Language and build | Keep the game core in a Swift package, independently testable from the AppKit app. |
| State | Translate persistent zero-page values to named state fields and short-lived scratch values to local calculations. Keep a mapping to original addresses. |
| Game step | Sample input once, advance `GameState`, and report player, world, and guard events. Preserve the original call order; schedule steps independently of host display refresh. |
| Display | Draw original sprites on a 28×16 board in a 280×192 image. Derive artifact colors from bits; scale output by integer pixels. |
| Input and audio | Map macOS keys to the meanings of the two original command fields. Handle substitute audio in an adapter outside the core. |
| Data | Extract 150 256-byte level sectors from `apple2/disk/track_*.asm`. Preserve each sector's trailing 32 bytes when replacing its 4-bit board. |

```text
macOS app -- sampled keys --> input mapping --> GameState.advance
    ^                                           |
    |                                           +-- two boards, player, guards, timers
    |                                           +-- gameplay events --> renderer / audio
    +------------------- displayed frame <------+
```

## Translating 6502 conventions

| 6502 representation | Swift representation | Invariant |
| --- | --- | --- |
| `$00`–`$05` player state | `PlayerState` cell, `xOffset/yOffset`, animation, facing | Offsets are 0...4, with 2 aligned. |
| `$0800`/`$0A00` boards and `PTR1/PTR2` | `activeBoard`, `backgroundBoard`, indexed by row and column | Do not confuse moving occupants with terrain. |
| `$0C60` guard array and `$12`–`$19` scratch | `[GuardState]` and local values for one guard | Preserve the read and write points of `LOAD_GUARD_DATA` / `STORE_GUARD_DATA`. |
| `$85/$86`, `$1B/$1C` drawing arguments | Local sprite, row, column, and page values | Drawing coordinates must not overwrite persistent player coordinates. |
| Carry-flag returns | Explicit success or failure results | Preserve the `MOVE_PLAYER` fallback from a failed primary command to horizontal movement. |
| `RTS` address-table dispatch | Explicit action selection | Preserve input and guard-action branch order. |
| Self-modified operands | Named state fields or table indices | Do not lose implicit state stored in instructions. |
| Eight-bit arithmetic and BCD score | Bounded integers and explicit score conversion | Check overflow, sign bits, and special `$FF` values against the original. |

The renderer owns HGR addresses, masks, and row pointers. Shared zero-page addresses such as `$55`, `$56`, and `$5C` become separate values for their separate uses.

## Verification stages

| Stage | Work | Completion criterion |
| --- | --- | --- |
| 0. Baseline | Freeze original binaries and level sectors; capture input and state scenarios from a 6502 execution environment. | Repeatable records of level, player cell and offsets, board changes, gold, guards, and timers. |
| 1. Data and boards | Decode sectors, sprites, both boards, and level-start state. | All 150 packed boards round-trip; representative initial states match the original. |
| 2. Player | Port `MOVE_PLAYER` digging, falling, input priority, movement, and gold collection. | Cell, offsets, board, and gold count match captured movement scenarios. |
| 3. World rules | Port holes, exit ladders, completion, death, lives, and score. | Entrapment, zero-gold, and top-row transitions match original state changes. |
| 4. Guards | Port patterns, route choice, gold transport, and resurrection. | Guard positions and actions match for identical input sequences. |
| 5. macOS app | Connect keyboard, display, fixed-step scheduler, and audio. | Play from the first level through Game Over with stable input and integer pixel scaling. |
| 6. Remaining features | Finish extended progression validation, high scores, attract mode, editor, and user levels if needed. | Original major screens and editing/storage flows can be completed in the app. |

Compare state in original game-step order, rather than judging rule accuracy from appearance alone. A useful trace records step number, input, and changed fields. `PLAY_SOUND` also delayed the original loop, so host timing needs separate calibration; monitor refresh rate must not define rule time.

## Current priorities

1. Compare long guard movement sequences on more levels, including carried gold and hole interactions.
2. Capture complete death, restart, and level-boundary traces from the original and compare session state.
3. Keep HGR byte-level rendering and speaker-cycle replication outside gameplay validation unless a concrete rule difference requires them.

## macOS API references

- [Apple CGImage](https://developer.apple.com/documentation/coregraphics/cgimage)
- [Apple SwiftUI image interpolation](https://developer.apple.com/documentation/swiftui/fitting-images-into-available-space)
- [Apple NSEvent](https://developer.apple.com/documentation/appkit/nsevent)
- [Apple AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
