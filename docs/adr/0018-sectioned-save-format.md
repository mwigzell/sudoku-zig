# ADR-0018 — Sectioned SUD0 save format

Status: accepted
Date: 2026-11-05

## Context

The first save-format design planned reserved bytes in the header and trailer, so fields could be added later without moving offsets. They were dropped before the code was written: the shipped layout was a fixed header, the history entries, and a fixed trailer (givens and board). From then on, each addition bumped the version instead. Solve history was version 2; the saved status (256 bytes, padded) was version 3. Each version kept its own read path.

A version bump protects the app that writes the file, but an older app refuses any newer version. Reserved bytes would have let older apps read newer files until the reserved space ran out. Pencil marks were about to need version 4. Nothing had shipped, so this was the last point where the format could change without keeping old read paths forever.

## Decision

- **Header:** `"SUD0"`, `version: u16` (restarts at 1), `section_count: u16`, little-endian.
- **Sections:** `tag: u8, len: u32, payload`. Today: board (81 values), givens (16 bytes), history, status (text at its own length, up to 256 bytes), marks (nine 16-byte cell masks, one per digit). Board and givens are required; the rest are optional.
- **History payload:** `pointer: u16`, then entries `tag: u8, len: u8, payload`. Today: cell edit (2 bytes, then the cell's marks before and the cells whose mark it cleared, 18 bytes), solve (givens and board before, 97 bytes, then the marks before, 144 bytes) and mark toggle (2 bytes).
- **Unknown tags are skipped,** for sections and for history entries. A skipped entry does not count toward the undo pointer.
- **Entries may grow.** A later version may append fields to an entry but never changes the ones already there. A reader reads the fields it knows and ignores bytes after them, and reads an entry without the appended fields (written before them) with their defaults; an entry shorter than its first fields is refused. So an app without marks still opens a file with marks and still undoes cell values; only the marks are missing.
- **New data is a new tag, never a version bump.** The version changes only when an existing section or entry changes meaning.
- **Versions 1–3 are dropped.** An old file reads as version 0 (its major and minor bytes are zero) and is refused like any unknown version.
- **A bad file is refused, never a crash:** truncation, a length past the end, an out-of-range cell value or coordinate. The engine shows its one "not a saved game" message for every refusal.

## Consequences

- An older app opens a newer file and ignores what it does not know. Pencil marks arrive as a marks section, a mark-toggle entry, and fields appended to the cell and solve entries.
- Ignoring unknown history entries means an older app's undo may not match the history a newer app wrote. Board and givens are read from their own sections, so the board shown is always right.
- A history entry's payload is at most 255 bytes.
- Saves made before this change no longer open; none exist outside development.
