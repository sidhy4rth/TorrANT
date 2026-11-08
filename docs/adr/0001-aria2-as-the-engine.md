# ADR-0001: aria2 carries the downloads; the app is the colony

**Date**: 2026-11-07
**Status**: accepted
**Deciders**: Sidhyarth

## Context

TorrANT needs two very different kinds of download: BitTorrent swarms (DHT,
peer exchange, magnet metadata, piece hashing, seeding) and plain links split
across several connections. Both are full of edge cases that take years to get
right, and neither is what makes TorrANT worth using. The colony is.

## Decision

aria2 does all the carrying. The app starts `aria2c` as a separate process
(`Sources/TorrANT/Aria2.swift`), talks to it over JSON-RPC on `127.0.0.1` with
a random port and a per-launch secret, and polls it four times a second
(`Colony.refresh`). `--stop-with-process` ties aria2's life to the app's, and
`--save-session` lets unfinished downloads survive a quit or a reboot.

## Alternatives Considered

### libtorrent, linked into the app
- **Pros**: one process; a richer torrent API.
- **Cons**: C++ build in a SwiftPM app; still needs a separate HTTP downloader for crumbs.
- **Why not**: twice the integration for no visible gain.

### URLSession for crumbs, a library for swarms
- **Pros**: Apple's networking for plain links.
- **Cons**: segmented downloads, resume and retries all hand-written.
- **Why not**: aria2 already does both, in one engine with one progress model.

## Consequences

### Positive
- Swarms and crumbs share one list, one progress model and one session file.
- The app never touches the network itself.

### Negative
- aria2 is GPL-2.0 and is run as a separate program, never linked.
- For now it comes from Homebrew, so TorrANT only runs where it's installed.

### Risks
- Bundling aria2 and its libraries into the `.app` is still to do; until then a
  Homebrew upgrade could change its behaviour under the app.
