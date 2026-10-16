#!/usr/bin/env python3
"""A self-contained noweb weaver and tangler.

This replaces the (deprecated) noweb command-line tools `noweave` and
`notangle`.  It reads a single `.nw` literate-programming file and can:

  * weave it into a LaTeX `.tex` file that uses the noweb macros defined in
    the bundled `noweb.sty` (no noweb installation required), and
  * tangle it into an assembly source file by expanding the root chunk
    `<<*>>`.

It is based on the weaver written for the Ali Baba reverse-engineering
project (https://github.com/XekriRedmane/ali_baba_reveng), which in turn was
based on https://www.stat.auckland.ac.nz/~ihaka/software/Rnoweb.  It has been
adapted for Lode Runner, whose chunk names are much richer than Ali Baba's:
they may contain `[[quoted code]]`, spaces, operators (`+ = / *`),
parentheses and digits.

Tangling notes specific to this project:

  * The root chunk is `<<*>>` (not a filename chunk).
  * Every chunk reference (`<<name>>`) appears alone on its line, preceded only
    by whitespace.  The referenced chunk is expanded with *no* extra
    indentation -- exactly the behaviour the old toolchain obtained by running
    `notangle` through the `ignore_preuse_text.py` filter.  The referencing
    line's leading whitespace is therefore discarded.

Usage:
    python weave.py main.nw            # weave -> main.tex
    python weave.py main.nw -o out.tex # weave -> out.tex
    python weave.py main.nw --tangle main2.asm   # tangle root <<*>> -> main2.asm
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import hashlib
import pathlib
import re
from typing import Sequence, TextIO


# A chunk definition header, e.g. "<<defines>>=" at the start of a line.
CHUNKSTART = re.compile(r"(^<<.*>>=\s*$)|(^@ )|(^@$)")
# A documentation-chunk header ("@ ..." or a bare "@").
DOCCHUNKSTART = re.compile(r"(^@ )|(^@$)")
# Used by extract_chunk_name to peel "<<" ... ">>=" off a code-chunk header.
CODECHUNKSTART = re.compile(r"^.*<<\s*")
CODECHUNKEND = re.compile(r"\s*>>=?.*$")
# A chunk reference anywhere on a line; the name may contain anything but ">".
CHUNKREF = re.compile(r"<<([^>]*)>>")
# A "pure use" line: optional whitespace, a single reference, optional
# whitespace.  Every reference in this document is of this form.
PUREUSE = re.compile(r"^\s*<<([^>]*)>>\s*$")

LABELPREFIXSTART = "PYNW"

# "@ %def foo bar" associates identifiers with the preceding code chunk.
ISDEF = re.compile(r"^@\s+%def.*$")
DEFPREFIX = re.compile(r"^@\s+%def\s+")
# A crude identifier: a run of word characters starting with a letter/underscore.
IDENT = re.compile(r"\b[a-zA-Z_]\w*\b")
# Quoted code within a documentation line: [[ ... ]].
QUOTED = re.compile(r"\[\[(.*?)\]\]")


@dataclasses.dataclass
class ChunkInfo:
    # The names of the chunks referenced in this chunk.
    names_used: set[str]
    # The labels of the chunks referenced in this chunk.
    labels_used: set[str]
    # The sublabels of chunks that this chunk is used in. Ordered.
    sublabels_used_in: list[str]
    # The identifiers defined in this chunk.
    defines: set[str]
    # The identifiers defined in other chunks that are used in this chunk.
    defines_used: set[str]

    # The sequence number of the chunk.
    number: int = 0
    # The (canonicalized) name of the chunk.
    name: str = ""
    # The kind is "doc" for documentation chunks and "code" for code chunks.
    kind: str = ""
    # The chunk label. There is a 1-1 correspondence between names and labels.
    label: str = ""
    # The chunk sublabel. Each chunk has a unique sublabel.
    sublabel: str = ""
    # The first line of the chunk (includes the header).
    start: int = 0
    # The last line of the chunk.
    end: int = 0
    # If this chunk continues a previous chunk, the sublabel of the previous.
    prev_sublabel: str = ""
    # If this chunk is continued by a subsequent chunk, its sublabel.
    next_sublabel: str = ""
    # The label prefix for this chunk.
    prefix: str = ""

    def __init__(self) -> None:
        self.names_used = set()
        self.labels_used = set()
        self.sublabels_used_in = []
        self.defines = set()
        self.defines_used = set()


class Weaver:
    def __init__(self) -> None:
        # Whether the documentation weaver is currently inside a `[[...]]`
        # quoted-code span.  Such spans may cross line boundaries.
        self.in_quote = False

    # ------------------------------------------------------------------
    # Chunk-name handling
    # ------------------------------------------------------------------

    def extract_chunk_name(self, header: str) -> str:
        """Returns the canonical name of a chunk from its header line.

        Documentation chunks have no name.  Code-chunk headers look like
        "<<name>>=", where the name may contain arbitrary characters other
        than ">".
        """
        if DOCCHUNKSTART.search(header):
            return ""
        header = re.sub(CODECHUNKSTART, "", header)
        header = re.sub(CODECHUNKEND, "", header)
        return header.strip()

    def prefix_for_chunk_name(self, name: str, filename: str, fileno: int) -> str:
        """Produces a label prefix for a chunk, used in cross-referencing.

        The label prefix consists of "PYNW" followed by a pseudohash of the
        filename and (its unique) file number, followed by "-", followed by a
        base32-encoded md5 hash of the name.  It need not be human-readable,
        only acceptable as a LaTeX label containing a single dash.
        """
        if not name:
            return ""
        name_hash = hashlib.md5(name.encode()).digest()
        encoded_hash = base64.b32encode(name_hash).decode().replace("=", "0")
        # Use only the basename, keeping alphanumeric characters, so the label
        # is a valid LaTeX control-sequence name even when `filename` is an
        # absolute path containing backslashes, colons, or spaces.
        stem = re.sub(r"[^0-9A-Za-z]", "", pathlib.Path(filename).name)[:3]
        return f"{LABELPREFIXSTART}{stem}{fileno}-{encoded_hash}"

    def make_safe_string(self, s: str) -> str:
        """Escapes a string for typesetting inside noweb code (\\code..\\edoc)."""
        trans_table = str.maketrans(
            {
                "\\": r"{\textbackslash}",
                "{": r"\{",
                "}": r"\}",
                "_": r"{\_}",
                "$": r"{\$}",
                " ": r"\ ",
                "&": r"{\&}",
                "#": r"{\#}",
                "%": r"{\%}",
                "~": r"{\textasciitilde}",
                "^": r"{\textasciicircum}",
            }
        )
        return s.translate(trans_table)

    def escape_roman(self, s: str) -> str:
        """Escapes LaTeX specials in roman (non-code) text, keeping spaces."""
        trans_table = str.maketrans(
            {
                "\\": r"{\textbackslash}",
                "{": r"\{",
                "}": r"\}",
                "_": r"{\_}",
                "$": r"{\$}",
                "&": r"{\&}",
                "#": r"{\#}",
                "%": r"{\%}",
                "~": r"{\textasciitilde}",
                "^": r"{\textasciicircum}",
            }
        )
        return s.translate(trans_table)

    def render_chunk_name(self, name: str) -> str:
        r"""Renders a chunk name for the woven output.

        `[[quoted code]]` portions become `\code{}...\edoc{}` (typewriter),
        while the surrounding roman text keeps its interword spaces.  For
        example, "set pointer [[PTR2]] for [[Y+1]]" becomes
        "set pointer \code{}PTR2\edoc{} for \code{}Y+1\edoc{}".
        """
        out: list[str] = []
        pos = 0
        for m in QUOTED.finditer(name):
            if m.start() > pos:
                out.append(self.escape_roman(name[pos : m.start()]))
            out.append(r"\code{}" + self.make_safe_string(m.group(1)) + r"\edoc{}")
            pos = m.end()
        if pos < len(name):
            out.append(self.escape_roman(name[pos:]))
        return "".join(out)

    # ------------------------------------------------------------------
    # Chunk analysis
    # ------------------------------------------------------------------

    def chunk_used_names(self, lines: Sequence[str], kind: str) -> set[str]:
        """Returns the set of chunk names referenced in a code chunk."""
        if kind == "doc":
            return set()
        names: set[str] = set()
        for line in lines:
            for m in CHUNKREF.finditer(line):
                names.add(m.group(1).strip())
        return names

    def chunk_defines_used(
        self,
        lines: Sequence[str],
        chunk: ChunkInfo,
        chunks_by_defines: dict[str, ChunkInfo],
    ) -> set[str]:
        """Returns identifiers defined in other chunks that are used here.

        Finding identifiers is highly language-specific, so we do the bare
        minimum: an identifier is a run of word characters.  Identifiers are
        assumed global, so a local use matching a global name is treated as a
        use of the global.
        """
        if chunk.kind == "doc":
            return set()
        idents: list[str] = []
        for line in lines[chunk.start + 1 : chunk.end]:
            line = re.sub(CHUNKREF, "", line)
            idents.extend(re.findall(IDENT, line))
        return set(
            ident
            for ident in idents
            if ident in chunks_by_defines and ident not in chunk.defines
        )

    def extract_chunk_info(
        self, lines: list[str], filename: str, fileno: int
    ) -> list[ChunkInfo]:
        """Extracts information about every chunk in an nw file."""
        starts: list[int] = [i for i, line in enumerate(lines) if CHUNKSTART.search(line)]
        ends = starts[1:] + [len(lines)]

        chunks = [ChunkInfo() for _ in range(len(starts))]

        label_counts: dict[str, int] = {}
        curr_sublabel_by_label: dict[str, str] = {}

        for i, (chunk, start, end) in enumerate(zip(chunks, starts, ends)):
            chunk.number = i + 1
            chunk.start = start
            chunk.end = end

            chunk.name = self.extract_chunk_name(lines[start])
            chunk.kind = "code" if chunk.name else "doc"
            chunk.prefix = self.prefix_for_chunk_name(chunk.name, filename, fileno)

            chunk.label = f"{chunk.prefix}-1" if chunk.name else ""
            label_counts[chunk.label] = label_counts.get(chunk.label, 0) + 1

            chunk.sublabel = (
                f"{chunk.prefix}-{label_counts[chunk.label]}" if chunk.name else ""
            )

            chunk.prev_sublabel = curr_sublabel_by_label.get(chunk.label, "")
            curr_sublabel_by_label[chunk.label] = chunk.sublabel

        for i, chunk in enumerate(chunks):
            for j in range(i + 1, len(chunks)):
                if chunks[j].label == chunk.label:
                    chunks[i].next_sublabel = chunks[j].sublabel
                    break

        prefixes_by_name = {chunk.name: chunk.prefix for chunk in chunks}
        labels_by_name = {chunk.name: chunk.label for chunk in chunks}

        for chunk in chunks:
            chunk.names_used = self.chunk_used_names(
                lines[chunk.start + 1 : chunk.end], chunk.kind
            )

        for chunk in chunks:
            for name in chunk.names_used:
                if name not in prefixes_by_name:
                    raise ValueError(
                        f"Reference to chunk <<{name}>> in chunk <<{chunk.name}>> "
                        "not found in defined chunks."
                    )
                chunk.labels_used.add(labels_by_name[name])

        for chunk in chunks:
            for chunk2 in chunks:
                if chunk.label and chunk.label in chunk2.labels_used:
                    chunk.sublabels_used_in.append(chunk2.sublabel)

        # Identifiers defined in each chunk.  "@ %def" starts a doc chunk whose
        # defines apply to the *previous* code chunk.
        chunks_by_defines: dict[str, ChunkInfo] = {}
        for i, chunk in enumerate(chunks):
            if i == 0 or chunk.kind != "doc" or chunks[i - 1].kind != "code":
                continue
            header = lines[chunk.start]
            m = re.search(DEFPREFIX, header)
            if not m:
                continue
            code_chunk = chunks[i - 1]
            code_chunk.defines = set(header[m.end() :].split())
            for d in code_chunk.defines:
                if d in chunks_by_defines and chunks_by_defines[d].name != code_chunk.name:
                    raise ValueError(
                        f"Identifier {d} defined in multiple chunks: "
                        f"{chunks_by_defines[d].name} and {code_chunk.name}."
                    )
                chunks_by_defines[d] = code_chunk

        for chunk in chunks:
            chunk.defines_used = self.chunk_defines_used(lines, chunk, chunks_by_defines)

        return chunks

    # ------------------------------------------------------------------
    # Weaving (nw -> tex)
    # ------------------------------------------------------------------

    def weave_doc_line(self, line: str, f: TextIO) -> None:
        r"""Weaves one documentation line, handling `[[...]]` quoted code.

        Text outside quotes is passed through to LaTeX verbatim; text inside
        quotes is set in typewriter and escaped with `make_safe_string`.  A
        quote may span several lines: `[[` opens with `{\Tt{}`, `]]` closes
        with `\nwendquote}`, and every newline reached while still inside the
        quote emits `\nwnewline`.  `self.in_quote` carries the open/closed state
        between successive calls.
        """
        out: list[str] = []
        i, n = 0, len(line)
        while i < n:
            if not self.in_quote:
                j = line.find("[[", i)
                if j == -1:
                    out.append(line[i:])
                    break
                out.append(line[i:j])
                out.append(r"{\Tt{}")
                self.in_quote = True
                i = j + 2
            else:
                j = line.find("]]", i)
                if j == -1:
                    out.append(self.make_safe_string(line[i:]))
                    break
                out.append(self.make_safe_string(line[i:j]))
                out.append(r"\nwendquote}")
                self.in_quote = False
                i = j + 2
        if self.in_quote:
            out.append(r"\nwnewline")
        f.write("".join(out) + "\n")

    def weave_begin_doc_chunk(self, chunk_num: int, initial_line: str, f: TextIO) -> None:
        f.write(r"\nwbegindocs{")
        f.write(str(chunk_num))
        f.write("}")
        if not initial_line:
            f.write(r"\nwdocspar")
            f.write("\n")
        else:
            self.weave_doc_line(initial_line, f)

    def weave_end_doc_chunk(self, f: TextIO) -> None:
        f.write(r"\nwenddocs{}")

    def weave_doc_chunk(self, lines: Sequence[str], chunk: ChunkInfo, f: TextIO) -> None:
        initial_line = lines[chunk.start]
        if initial_line == "@" or re.search(ISDEF, initial_line):
            initial_line = ""
        initial_line = re.sub(r"^@ ", "", initial_line)
        self.weave_begin_doc_chunk(chunk.number, initial_line, f)
        for line in lines[chunk.start + 1 : chunk.end]:
            self.weave_doc_line(line, f)
        self.weave_end_doc_chunk(f)

    def weave_begin_code_chunk(
        self,
        chunk_num: int,
        chunk_name: str,
        chunk_label: str,
        chunk_sublabel: str,
        f: TextIO,
    ) -> None:
        f.write(r"\nwbegincode{")
        f.write(str(chunk_num))
        f.write(r"}")
        f.write(r"\sublabel{")
        f.write(chunk_sublabel)
        f.write(r"}")
        f.write(r"\nwmargintag{{\nwtagstyle{}\subpageref{")
        f.write(chunk_sublabel)
        f.write(r"}}}")
        f.write(r"\moddef{")
        f.write(self.render_chunk_name(chunk_name))
        f.write(r"~{\nwtagstyle{}\subpageref{")
        f.write(chunk_label)
        f.write(r"}}}")
        f.write(r"\plusendmoddef" if chunk_sublabel != chunk_label else r"\endmoddef")

    def weave_defline_markup(self, chunk: ChunkInfo, f: TextIO) -> None:
        f.write(r"\nwstartdeflinemarkup")
        if chunk.sublabels_used_in:
            f.write(r"\nwusesondefline{")
            for label in chunk.sublabels_used_in:
                f.write(r"\\{")
                f.write(label)
                f.write(r"}")
            f.write(r"}")
        if chunk.prev_sublabel or chunk.next_sublabel:
            f.write(r"\nwprevnextdefs{")
            f.write(chunk.prev_sublabel if chunk.prev_sublabel else r"\relax")
            f.write(r"}{")
            f.write(chunk.next_sublabel if chunk.next_sublabel else r"\relax")
            f.write(r"}")
        f.write(r"\nwenddeflinemarkup")

    def weave_not_used_chunk(self, name: str, f: TextIO) -> None:
        f.write(r"\nwnotused{")
        f.write(self.render_chunk_name(name))
        f.write(r"}")

    def weave_insert(self, line: str, name_to_label: dict[str, str], f: TextIO) -> None:
        """Weaves a code line containing a chunk reference."""
        while re.search(CHUNKREF, line):
            pre_text = re.search(r"^(.*?)<<.*$", line)
            if not pre_text:
                break
            f.write(pre_text.group(1))
            line = line[len(pre_text.group(1)) :]
            text = re.search(CHUNKREF, line)
            if not text:
                break
            name = text.group(1).strip()
            line = line[text.end() :]
            label = name_to_label[name]
            f.write(r"\LA{}")
            f.write(self.render_chunk_name(name))
            f.write(r"~{\nwtagstyle{}\subpageref{")
            f.write(label)
            f.write(r"}}\RA{}")
        f.write("\n")

    def weave_code_line(
        self, line: str, ident_to_chunk: dict[str, ChunkInfo], f: TextIO
    ) -> None:
        r"""Maps special characters and links defined identifiers."""
        line = re.sub("@<<", "<<", line)
        line = re.sub("\\\\", "\\\\\\\\", line)
        line = re.sub("\\}", "\\\\}", line)
        line = re.sub("\\{", "\\\\{", line)
        matches = list(re.finditer(IDENT, line))
        matches.reverse()
        for match in matches:
            ident = match.group(0)
            if ident not in ident_to_chunk:
                continue
            line = (
                line[: match.start()]
                + r"\nwlinkedidentc{"
                + ident
                + r"}{"
                + ident_to_chunk[ident].sublabel
                + r"}"
                + line[match.end() :]
            )
        f.write(line + "\n")

    def weave_defines(
        self, chunk: ChunkInfo, ident_to_chunk: dict[str, ChunkInfo], f: TextIO
    ) -> None:
        if not chunk.defines:
            return
        sorted_defines = sorted(chunk.defines)
        for ident in sorted_defines:
            f.write(r"\nwindexdefn{\nwixident{")
            f.write(ident.replace("_", r"{\_}"))
            f.write(r"}}{")
            f.write(ident.replace("_", ":un"))
            f.write(r"}{")
            f.write(ident_to_chunk[ident].sublabel)
            f.write(r"}")
        f.write(r"\eatline")
        f.write("\n")

        f.write(r"\nwidentdefs{")
        for ident in sorted_defines:
            f.write(r"\\{{\nwixident{")
            f.write(ident.replace("_", r"{\_}"))
            f.write(r"}}{")
            f.write(ident.replace("_", ":un"))
            f.write(r"}}")
        f.write(r"}")

    def weave_define_uses(
        self, chunk: ChunkInfo, ident_to_chunk: dict[str, ChunkInfo], f: TextIO
    ) -> None:
        if not chunk.defines_used:
            return
        sorted_defines = sorted(chunk.defines_used)
        f.write(r"\nwidentuses{")
        for ident in sorted_defines:
            f.write(r"\\{{\nwixident{")
            f.write(ident.replace("_", r"{\_}"))
            f.write(r"}}{")
            f.write(ident.replace("_", ":un"))
            f.write(r"}}")
        f.write(r"}")
        for ident in sorted_defines:
            f.write(r"\nwindexuse{\nwixident{")
            f.write(ident.replace("_", r"{\_}"))
            f.write(r"}}{")
            f.write(ident.replace("_", ":un"))
            f.write(r"}{")
            f.write(chunk.sublabel)
            f.write(r"}")

    def weave_end_code_chunk(self, f: TextIO) -> None:
        f.write(r"\nwendcode{}")

    def weave_code_chunk(
        self,
        lines: Sequence[str],
        name_to_label: dict[str, str],
        ident_to_chunk: dict[str, ChunkInfo],
        chunk: ChunkInfo,
        f: TextIO,
    ) -> None:
        unused = not chunk.sublabels_used_in
        self.weave_begin_code_chunk(
            chunk.number, chunk.name, chunk.label, chunk.sublabel, f
        )
        self.weave_defline_markup(chunk, f)
        f.write("\n")

        for line in lines[chunk.start + 1 : chunk.end]:
            if re.search(CHUNKREF, line) is not None:
                self.weave_insert(line, name_to_label, f)
            else:
                self.weave_code_line(line, ident_to_chunk, f)

        self.weave_defines(chunk, ident_to_chunk, f)
        if unused:
            self.weave_not_used_chunk(chunk.name, f)
        self.weave_define_uses(chunk, ident_to_chunk, f)
        self.weave_end_code_chunk(f)

    def weave_chunk_index(self, chunks: Sequence[ChunkInfo], f: TextIO) -> None:
        labels_by_name = {chunk.name: chunk.label for chunk in chunks}
        sublabels_by_name: dict[str, list[str]] = {}
        for chunk in chunks:
            if chunk.name:
                sublabels_by_name.setdefault(chunk.name, []).append(chunk.sublabel)
        uses_by_name: dict[str, list[str]] = {}
        for chunk in chunks:
            for name in chunk.names_used:
                uses_by_name.setdefault(name, []).append(chunk.label)

        chunk_names = sorted({chunk.name for chunk in chunks if chunk.name})
        for name in chunk_names:
            f.write(r"\nwixlogsorted{c}{{")
            f.write(self.render_chunk_name(name))
            f.write(r"}{")
            f.write(labels_by_name[name])
            f.write(r"}{")
            for use in uses_by_name.setdefault(name, []):
                f.write(r"\nwixu{")
                f.write(use)
                f.write(r"}")
            for sublabel in sublabels_by_name[name]:
                f.write(r"\nwixd{")
                f.write(sublabel)
                f.write(r"}")
            f.write(r"}}%")
            f.write("\n")

    def weave_ident_index(self, chunks: Sequence[ChunkInfo], f: TextIO) -> None:
        idents = sorted({ident for chunk in chunks for ident in chunk.defines})
        for ident in idents:
            f.write(r"\nwixlogsorted{i}{{\nwixident{")
            f.write(ident.replace("_", r"{\_}"))
            f.write(r"}}{")
            f.write(ident.replace("_", ":un"))
            f.write(r"}}%")
            f.write("\n")

    def weave(
        self,
        lines: Sequence[str],
        chunks: Sequence[ChunkInfo],
        texpath: pathlib.Path,
        filename: str,
    ) -> None:
        """Weaves an nw file into a LaTeX file."""
        self.in_quote = False
        last_doc = 0
        for chunk in chunks:
            if not chunk.name:
                last_doc = chunk.number

        name_to_label = {chunk.name: chunk.label for chunk in chunks}
        ident_to_chunk: dict[str, ChunkInfo] = {}
        for chunk in chunks:
            for ident in chunk.defines:
                ident_to_chunk[ident] = chunk

        with open(texpath, mode="w", newline="\n") as f:
            if chunks[0].start > 0:
                for line in lines[: chunks[0].start]:
                    self.weave_doc_line(line, f)

            for chunk in chunks:
                if chunk.number == last_doc:
                    f.write("\n\n")
                    self.weave_chunk_index(chunks, f)
                    self.weave_ident_index(chunks, f)
                if chunk.number == 1:
                    f.write(r"\nwfilename{" + pathlib.Path(filename).name + "}")
                if not chunk.name:
                    self.weave_doc_chunk(lines, chunk, f)
                else:
                    self.weave_code_chunk(
                        lines, name_to_label, ident_to_chunk, chunk, f
                    )

            f.write("\n")

    # ------------------------------------------------------------------
    # Tangling (nw -> asm)
    # ------------------------------------------------------------------

    def collect_code(self, lines: Sequence[str], chunks: Sequence[ChunkInfo]) -> dict[str, list[str]]:
        """Concatenates, in document order, the bodies of like-named chunks."""
        code_content: dict[str, list[str]] = {}
        for chunk in chunks:
            if chunk.name:
                body = lines[chunk.start + 1 : chunk.end]
                code_content.setdefault(chunk.name, []).extend(body)
        return code_content

    def expand_chunk(
        self,
        name: str,
        code_content: dict[str, list[str]],
        parents: set[str],
        out: list[str],
    ) -> None:
        """Expands a chunk, replacing pure-use lines with their expansion.

        Every chunk reference in this document appears alone on its line,
        preceded only by whitespace.  Such a line is replaced by the (recursive)
        expansion of the referenced chunk with no added indentation, followed by
        one blank line: `notangle` emits the referenced chunk's body (each line
        terminated by its own newline) and then the newline that ended the
        reference line itself.  All other lines are emitted verbatim.  This
        reproduces the behaviour of the old `notangle | ignore_preuse_text.py`
        pipeline.
        """
        if name not in code_content:
            raise ValueError(f"Reference to undefined chunk <<{name}>>.")
        for line in code_content[name]:
            m = PUREUSE.match(line)
            if m:
                ref = m.group(1).strip()
                if ref in parents:
                    raise ValueError(
                        f"Chunk <<{ref}>> in chunk <<{name}>> would form a cycle."
                    )
                self.expand_chunk(ref, code_content, parents | {name}, out)
                out.append("")
            else:
                out.append(line)

    def tangle(
        self,
        lines: Sequence[str],
        chunks: Sequence[ChunkInfo],
        outpath: pathlib.Path,
        root: str = "*",
    ) -> None:
        """Tangles the root chunk into a source file."""
        code_content = self.collect_code(lines, chunks)
        out: list[str] = []
        self.expand_chunk(root, code_content, set(), out)
        with open(outpath, mode="w", newline="\n") as f:
            for line in out:
                f.write(line + "\n")

    # ------------------------------------------------------------------
    # Driver
    # ------------------------------------------------------------------

    def run(
        self,
        nwfile: str,
        texpath: pathlib.Path | None,
        tanglepath: pathlib.Path | None,
        root: str,
    ) -> None:
        with open(nwfile, mode="r") as f:
            lines = [line.rstrip("\n") for line in f.readlines()]
        chunks = self.extract_chunk_info(lines, nwfile, 0)
        if texpath is not None:
            self.weave(lines, chunks, texpath, nwfile)
        if tanglepath is not None:
            self.tangle(lines, chunks, tanglepath, root)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("nwfile", help="the .nw literate source file")
    parser.add_argument(
        "-o",
        "--output",
        default=None,
        help="woven LaTeX output path (default: <nwfile>.tex; use '-' or "
        "--no-weave to skip weaving)",
    )
    parser.add_argument(
        "--no-weave", action="store_true", help="do not produce a .tex file"
    )
    parser.add_argument(
        "--tangle",
        metavar="PATH",
        default=None,
        help="also tangle the root chunk into PATH",
    )
    parser.add_argument(
        "--root", default="*", help="root chunk to tangle (default: '*')"
    )
    args = parser.parse_args()

    texpath: pathlib.Path | None
    if args.no_weave:
        texpath = None
    elif args.output:
        texpath = pathlib.Path(args.output)
    else:
        texpath = pathlib.Path(args.nwfile).with_suffix(".tex")

    tanglepath = pathlib.Path(args.tangle) if args.tangle else None

    Weaver().run(args.nwfile, texpath, tanglepath, args.root)


if __name__ == "__main__":
    main()
