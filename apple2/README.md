# Apple II reverse engineering source

This directory preserves the original Apple II Lode Runner reverse engineering project by [XekriRedmane](https://github.com/XekriRedmane/lode_runner_reveng). The literate source is `main.nw`; `main.pdf` is its rendered explanation. The `disk/` directory contains extracted track and sector data, and `sprite_data.asm` contains the original sprite bitmap table.

The original project's stated license is [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/). The macOS port in the parent directory is based on this material and retains the attribution and license terms.

To rebuild the Apple II binary and DOS 3.3 disk image, install `dasm` and run `python3 build.py` from this directory. `python3 build.py --verify` can additionally compare the generated image with the Internet Archive disk image when that image is supplied locally. See the [root README](../README.md) for the Swift port and its build instructions.
