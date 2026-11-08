# ADR-0002: Brave hands downloads over by native messaging, and cancels last

**Date**: 2026-11-08
**Status**: accepted
**Deciders**: Sidhyarth

## Context

Pasting links into TorrANT by hand is the one chore the app exists to remove.
Brave can tell an extension about every download it starts, but the extension
then has to reach a Mac app, with the site's cookies, without a pop-up on every
file, and without ever losing a download if the app is closed.

## Decision

`Extension/background.js` listens on `chrome.downloads.onDeterminingFilename`,
when Brave knows the name and size but has saved nothing, and sends the final
link, cookies, referrer and browser name to the native-messaging helper
`torrant-catch` (`Sources/TorrANTCatch/main.swift`). The helper forwards it over
an owner-only Unix socket to the app (`Sources/TorrANT/Catcher.swift`), which
adds it to aria2 and answers. **Brave's copy is cancelled only after that
answer says yes**; any error, timeout or closed app leaves the download in Brave.

The app registers the helper on every launch, allowing one extension ID, which
the `key` in `Extension/manifest.json` pins. It registers in **Chrome's**
`NativeMessagingHosts` folder as well as Brave's: Brave 154 on macOS reads
Chrome's, and the Brave folder alone gives "Specified native messaging host
not found".

## Alternatives Considered

### A custom URL scheme (`torrant://add?url=…`)
- **Pros**: no helper binary.
- **Cons**: Brave asks "Open TorrANT?" on every download, and cookies would travel in a URL.
- **Why not**: the pop-up is the chore we're removing.

### A local HTTP server in the app
- **Pros**: any extension or script can reach it.
- **Cons**: any web page can reach it too.
- **Why not**: native messaging only answers our extension ID; a socket only answers this user.

### Cancel in Brave first, then hand over
- **Pros**: Brave stops downloading sooner.
- **Cons**: a closed or crashed app loses the file.
- **Why not**: a download must never vanish in the hand-off.

## Consequences

### Positive
- No pop-ups, and signed-in downloads keep working.
- Closing TorrANT quietly returns Brave to normal.

### Negative
- Links that work only once, and files you get by submitting a form, fail when
  aria2 asks for them again.
- Unfinished signed-in downloads keep their cookies in aria2's session file
  until they finish.

### Risks
- The helper reply has to beat Brave's timeout even when macOS has App-Napped
  the app; the app takes a user-initiated activity while answering, and ignores
  SIGPIPE so a helper that gave up can't take it down (both found the hard way, 8 Nov).
