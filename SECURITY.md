# Security

TorrANT downloads files from the internet and takes downloads from your browser, so these are the
promises it makes and how each one is kept.

## Reporting a problem

Please don't open a public issue for a security problem. Use GitHub's
**Report a vulnerability** button on this repository (Security → Advisories), or contact the owner
directly through their GitHub profile. You'll get a reply, and a fix before anything is made public.

## What TorrANT promises

| Promise | How it's kept |
|---|---|
| **Nothing outside your Mac can control the download engine.** | aria2's control channel listens on `127.0.0.1` only, on a random port, behind a secret that is new every launch. aria2 masks the secret in the process list, so other programs can't read it from `ps`. |
| **Only TorrANT's own extension can hand it downloads.** | Brave's native-messaging registration lists exactly one extension ID (`ijnbceipkhodakjopoiccigfkphlokhf`, pinned by the key in `Extension/manifest.json`). Brave refuses every other extension. |
| **Only you can talk to the app's inbox.** | The helper reaches the app over a Unix socket in `~/Library/Application Support/TorrANT/`, created owner-only (`0600`). |
| **A download is never lost in the hand-off.** | Brave cancels its own copy only after TorrANT confirms the download is on the trail. Any error, timeout or closed app leaves the download in Brave. |
| **Your cookies go where the file is.** | The extension reads cookies for the final download link, after Brave has followed any redirects, so TorrANT starts at the file's own address with that site's cookies and not the cookies of the page that linked to it. |
| **No header tricks.** | Cookie, referrer and browser-name values have line breaks stripped before they become request headers. |
| **Private windows stay private.** | Downloads from private (incognito) windows are never handed over. |
| **A same-named file is never overwritten or "resumed".** | aria2 resumes only from its own progress files; anything else with the same name is left alone and the new file is saved as `name.1.ext`. |
| **No accounts, servers or tracking.** | TorrANT has no backend and sends nothing anywhere except the downloads you ask for. |

## Where data is kept

- `~/Library/Application Support/TorrANT/`: unfinished downloads (aria2's session, **including the
  cookies of signed-in downloads until they finish**), private copies of opened `.torrent` files, the
  Anthill history, and the engine log.
- `~/Downloads` (or the folder you chose): the downloads themselves.
- The Brave extension stores only its on/off switch, a caught count, the last caught file name and the
  last error, in the extension's own storage.

## Known gaps

- The app is ad-hoc signed, not notarised, so macOS can't vouch for a copy that came from elsewhere.
  Only run builds you made or got directly from the owner.
- BitTorrent shares pieces with other people by design, and your IP address is visible to the swarm.
  TorrANT doesn't hide it. Use a VPN if that matters to you.
- Torrent and download content isn't scanned yet. *Taste Test* (safe/poison) is on the roadmap.
