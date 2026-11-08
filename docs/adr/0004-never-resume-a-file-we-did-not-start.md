# ADR-0004: Never resume a file TorrANT didn't start

**Date**: 2026-11-08
**Status**: accepted
**Deciders**: Sidhyarth

## Context

With `--continue=true`, aria2 treats any existing file of the same name in the
download folder as a partial download of the new one. Testing the Brave
hand-off on 8 Nov showed what that means: a `crumbtest.bin` already in
Downloads was counted as "already finished", and a smaller unrelated file would
have been extended with the new file's bytes, corrupting both.

## Decision

Run aria2 with `--continue=false` (`Sources/TorrANT/Aria2.swift`). Downloads
TorrANT started still resume, because aria2 resumes from its own `.aria2`
progress files whatever this flag says. A same-named file with no progress file
is left alone, and `--auto-file-renaming` saves the new one as `name.1.ext`.

## Alternatives Considered

### Keep `--continue=true`
- **Pros**: could resume a file another program started.
- **Cons**: silently corrupts or skips any same-named file.
- **Why not**: browsers name files `download.zip` and `invoice.pdf` all day.

### Overwrite same-named files
- **Pros**: no `.1` names.
- **Cons**: destroys a file the user may want.
- **Why not**: TorrANT never deletes what it didn't create.

## Consequences

### Positive
- A download can never damage a file that was already there.

### Negative
- Two downloads of the same name end up as `name.ext` and `name.1.ext`.

### Risks
- None known. Re-checked on 8 Nov with this flag: aria2 killed mid-download,
  restarted, finished into the same file (not `.1`), byte-for-byte identical.
