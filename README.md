# lode_runner_reveng
Reverse engineering of Lode Runner for the Apple II series.

[main.pdf](main.pdf) is the literate programming document for this project. This means the explanatory text is interspersed with source code. The source code can be extracted from the document and compiled.

The goal is to provide all the source code and data necessary to reproduce a disk image byte-for-byte identical to the Internet Archive's [Lode_Runner_1983_Broderbund_cr_Reset_Vector.do](https://archive.org/details/a2_Lode_Runner_1983_Broderbund_cr_Reset_Vector).

The assembly code is assembled using [`dasm`](https://dasm-assembler.github.io/).

This document doesn't explain every last detail. It's assumed that the reader can find enough details on the 6502 processor and the Apple II series of computers to fill in the gaps.

## Useful 6502 and Apple II resources:

* [Beneath Apple DOS](https://archive.org/details/beneath-apple-dos), by Don Worth and Pieter Lechner, 1982.
* [Apple II Computer Graphics](https://archive.org/details/williams-et-al-1983-apple-ii-computer-graphics), by Ken Williams, Bob Kernaghan, and Lisa Kernaghan, 1983.
* [6502 Assembly Language Programming](https://archive.org/details/6502alp), by Lance A. Leventhal, 1979.
* [Beagle Bros Apple Colors and ASCII Values](https://archive.org/details/Beagle_Bros-Poster_1), Beagle Bros Micro Software Inc, 1984.
* [Hi-Res Graphics and Animation Using Assembly Language, The Guide for Apple II Programmers](https://archive.org/details/hi-res-graphics-and-animation-using-assembly-language), by Leanard I. Malkin, 1985.

## Compilation

This step should not be necessary, as the release provides the assembly files, the 6502 binary, and the PDF.

This project no longer depends on the (deprecated) [`noweb`](https://github.com/nrnrnr/noweb)
tools. Instead it ships a small, self-contained weaver/tangler,
[`weave.py`](weave.py), and a vendored copy of the noweb LaTeX macros,
[`noweb.sty`](noweb.sty). This approach mirrors the
[Ali Baba reverse-engineering project](https://github.com/XekriRedmane/ali_baba_reveng).

### Prerequisites

* [`dasm`](https://dasm-assembler.github.io/), the 6502 assembler.
* A distribution of [TeX Live](https://www.tug.org/texlive/) with the `booktabs` and `tikz` packages.
* Python 3.9 or later (standard library only — no third-party packages).

No `noweb` installation is required, and any current TeX Live works (the
bundled `noweb.sty` replaces the `noweb` LaTeX package, which recent TeX Live
releases no longer provide).

### Generating the binary and disk image

```sh
$ python build.py            # add --dasm PATH if dasm is not on your PATH
```

`build.py` tangles `main.nw` into assembly (expanding the `<<*>>` root chunk),
reorders the code so that `ORG` locations are increasing — `dasm` does not
handle code blocks whose origins jump around — assembles `main.asm` into
`main.bin`, and then reconstructs the original disk image as
`lode_runner.do`. Add `--verify` to compare `main.bin` against
`golden_source.bin` and `lode_runner.do` against the archive.org original
(place `Lode_Runner_1983_Broderbund_cr_Reset_Vector.do` in the project root;
it is not committed to the repository).

### How the disk image is reconstructed

The approach mirrors the
[Ali Baba reverse-engineering project](https://github.com/XekriRedmane/ali_baba_reveng):
`build.py` starts from a zero-filled 143,360-byte DOS-ordered (`.do`) image
and fills in each sector from its proper source:

* **The game itself** (tracks $12–$1A) is stored on the disk as an ordinary
  DOS 3.3 binary file — the catalog on track $11 lists it as `LODE RUNNER`,
  BSAVEd with address `A$800` and length `L$8100`. `build.py` lays out the
  file exactly the way DOS 3.3's BSAVE did: a 4-byte address/length header
  followed by the load image (memory $3F00–$BFFF, which is `main.bin`'s
  $0000–$1FFF followed by its $5F00–$BFFF), written across data sectors in
  DOS's descending-sector allocation order, with the two track/sector list
  sectors (track $12 sector $F and track $19 sector $4) generated in
  standard DOS 3.3 format. Even the slack bytes in the file's final sector
  (stale DOS write-buffer contents on the original disk) are reproduced.
* **Everything else** comes from the `disk/track_XX.asm` data files:
  the boot loader on tracks 0–2, the 150 levels stored raw on tracks
  3–$C (16 levels per track, one level per sector), and the DOS 3.3
  catalog on track $11.

The result is byte-for-byte identical to the Internet Archive's
`Lode_Runner_1983_Broderbund_cr_Reset_Vector.do`.

### Generating the PDF

```sh
$ python weave.py main.nw    # writes main.tex
$ pdflatex main.tex
$ pdflatex main.tex
```

Yes, you have to run `pdflatex` twice. The first run generates auxilliary information about indexes that the second run can use to properly cross-reference things. A build starting from scratch (no `main.aux`) may need a third run before the page cross-references settle; keep running `pdflatex` until it stops printing "Rerun to get cross-references right".

(`python build.py` also regenerates `main.tex` as part of its run, so you only
need to run `pdflatex` afterwards.)

## License

This work is licensed under a
[Creative Commons Attribution-ShareAlike 4.0 International License][cc-by-sa].

[![CC BY-SA 4.0][cc-by-sa-image]][cc-by-sa]

[cc-by-sa]: http://creativecommons.org/licenses/by-sa/4.0/
[cc-by-sa-image]: https://licensebuttons.net/l/by-sa/4.0/88x31.png
[cc-by-sa-shield]: https://img.shields.io/badge/License-CC%20BY--SA%204.0-lightgrey.svg
