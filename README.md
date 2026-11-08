<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.png">
  <img alt="TorrANT: torrents and links for your Mac" src="docs/assets/banner-light.png" width="720">
</picture>

### A Mac downloader for torrents and plain links, where every download is an ant carrying something home. No crumb too big.

![macOS](https://img.shields.io/badge/macOS-14%2B-0A0A0A?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![Engine](https://img.shields.io/badge/engine-aria2-D7261F)
![BitTorrent](https://img.shields.io/badge/BitTorrent-DHT_·_PEX_·_magnets-E5322D)
![Brave](https://img.shields.io/badge/Brave-catches_every_download-FB542B?logo=brave&logoColor=white)
![Status](https://img.shields.io/badge/status-v0.1_·_private-5A5551)

[**What it does**](#what-it-does) ·
[**Brave hand-off**](#catching-every-brave-download) ·
[**Design notes**](docs/adr/README.md) ·
[**Security**](SECURITY.md)

</div>

<br>

<p align="center">
  <img src="docs/assets/screen-colony.png" alt="The Colony: a Blender download and three torrents (Big Buck Bunny, Sintel, Debian) on the trail at 36.3 MB/s" width="100%">
</p>
<p align="center"><sub>The Colony, 8 Nov 2026. One crumb (a direct link to Blender, 8 ants pulling) and three swarms (Debian, Sintel, Big Buck Bunny) coming home at 36.3 MB/s together. Every number on this screen moves every frame and never goes backwards.</sub></p>

---

## At a glance

<table>
<tr>
<td align="center"><h3>2</h3>kinds of food<br><sub>swarms (torrents) and<br>crumbs (plain links)</sub></td>
<td align="center"><h3>8</h3>ants per crumb<br><sub>parallel connections<br>on one link</sub></td>
<td align="center"><h3>36.3 MB/s</h3>measured<br><sub>four downloads at once,<br>1.5 GB home in about a minute</sub></td>
<td align="center"><h3>Every frame</h3>live numbers<br><sub>speeds, sizes and bars<br>that never run backwards</sub></td>
<td align="center"><h3>1 click</h3>from Brave<br><sub>every download over 1 MB<br>goes to the ants</sub></td>
<td align="center"><h3>0</h3>accounts, servers<br>or tracking</td>
</tr>
</table>

**The story.** Ants live for the swarm. A torrent is a swarm: thousands of colonies sharing pieces of the
same thing, and TorrANT's ants join in, bring the pieces home and share some back. But an ant never walks
past food lying on the ground, so a plain download link is a crumb, grabbed on sight and dragged home by
eight ants at once. Everything that arrives goes into the Anthill.

The theme is there to make it fun; the screens are there to be read at a glance. Red means a swarm,
bone means a crumb, and every label says what it means in plain words.

---

## What it does

| | |
|---|---|
| **Joins swarms** | Torrents and magnet links, with DHT, peer exchange and local peer discovery, so the ants find each other without a tracker. Up to 80 peers per swarm. |
| **Grabs crumbs** | Plain HTTP, HTTPS and FTP links, split across 8 connections so one file comes home in parallel pieces. Up to 8 downloads run at once. |
| **Catches every Brave download** | A small Brave extension hands each download to TorrANT with your login for that site, so files behind a sign-in still work. [How it works ↓](#catching-every-brave-download) |
| **Lets you pick what to carry** | Opening a `.torrent` shows its files first: tick only the ones you want, choose the folder, start now or later. |
| **Spots crumbs on the clipboard** | Copy a download link or a magnet anywhere and a *Crumb spotted!* banner offers to grab it. |
| **Keeps the Mac awake** | While anything is downloading or queued, the Mac won't idle-sleep. The moment the trail is empty, it can sleep again. |
| **Shares back, then stops** | Finished torrents keep feeding other colonies until they've given back as much as they took (1×), then rest. |
| **Lives in the menu bar too** | *Ant Cam*: a pocket view of what's on the trail, with its own paste box. |
| **Survives restarts** | Unfinished downloads pick up where they left off after a quit or a reboot. |
| **Remembers what came home** | The Anthill keeps the last 200 arrivals: click to show one in Finder, double-click to open it. |

<table>
<tr>
<td width="62%"><img src="docs/assets/screen-home.png" alt="Everything home: the Anthill lists the arrivals and three torrents feed other colonies"><br><sub><b>Everything home.</b> 1.507 GB carried in, the trail empty, three swarms feeding other colonies, and the chatter: <i>"All quiet. The Mac can sleep again."</i></sub></td>
<td width="38%"><img src="docs/assets/screen-brave-popup.png" alt="The TorrANT Catcher popup in Brave"><br><sub><b>TorrANT Catcher</b>, the Brave extension. One switch, whether the colony is awake, and what it caught last.</sub></td>
</tr>
</table>

---

## How it works

```
   Brave                                          TorrANT.app
  ┌─────────────────────┐                        ┌──────────────────────────────┐
  │ TorrANT Catcher     │  native messaging      │ torrant-catch (helper)       │
  │ (MV3 extension)     │ ─────────────────────► │ length-prefixed JSON, stdio  │
  │ url, cookies,       │  only this extension   └──────────────┬───────────────┘
  │ referrer, browser   │  ID is allowed                        │ Unix socket, owner-only (0600)
  └─────────────────────┘                                       ▼
                                                 ┌──────────────────────────────┐
  paste box · drag & drop · clipboard ─────────► │ Colony (SwiftUI app state)   │
  magnet: links · .torrent files ──────────────► │ polls 4×/s, never redraws    │
                                                 │ unless something changed     │
                                                 └──────────────┬───────────────┘
                                                                │ JSON-RPC on 127.0.0.1,
                                                                │ random port + per-launch secret
                                                                ▼
                                                 ┌──────────────────────────────┐
                                                 │ aria2 (download engine)      │
                                                 │ swarms: DHT · PEX · LPD      │
                                                 │ crumbs: 8 connections        │
                                                 └──────────────┬───────────────┘
                                                                ▼
                                                     ~/Downloads ──► the Anthill
```

The app never touches the network itself. aria2, a long-standing open-source download engine, does the
carrying; TorrANT runs it in the background, talks to it only on `127.0.0.1` behind a secret that changes
every launch, and stops it when the app quits.

**Numbers that never run backwards.** aria2 reports speeds four times a second, which makes plain labels
jump and sometimes tick down. TorrANT keeps the last two samples and moves every speed, size and progress
bar smoothly between them, on Core Animation layers driven by the display's own refresh. Downloaded sizes
only ever grow. The first version drew this with SwiftUI's `TimelineView` and cost about 45% CPU; the layer
version costs a fraction of that. [ADR 0003](docs/adr/0003-live-numbers-on-layers.md).

---

## Catching every Brave download

Once TorrANT Catcher is loaded in Brave, every download Brave starts is offered to TorrANT the moment Brave
knows the file's name and size, before anything is saved.

1. **Catch.** The extension reads the link (after redirects), the page it came from, Brave's browser name
   and the site's cookies for that link.
2. **Hand over.** It sends them to TorrANT's helper through Brave's native messaging. TorrANT registers the
   helper on every launch and allows exactly one extension ID to use it.
3. **Confirm, then cancel.** Brave's copy is cancelled **only after** TorrANT says the download is on the
   trail. If TorrANT is closed, busy or says no, Brave simply keeps the download, so nothing is ever lost.

**What stays in Brave:** files under 1 MB, files whose size Brave doesn't know, downloads from private
windows, and everything while the switch is off. `.torrent` files are always handed over, since they're
small but always a swarm.

**Same file name, different file.** If `report.pdf` already sits in Downloads, the new one is saved as
`report.1.pdf`. Only a download TorrANT itself started is ever resumed.

[ADR 0002](docs/adr/0002-brave-hand-off-over-native-messaging.md) explains why it's built this way, and
the macOS quirk that took a day to find: Brave reads helper registrations from **Chrome's** folder.

---

## Checked by hand

Everything below was run on a real Mac (macOS 26, Apple Silicon) and looked at, not just compiled.

| What | How it was checked | Result |
|---|---|---|
| Torrents | Debian 13.7 netinst, Sintel and Big Buck Bunny (Blender's open movies) | Home; Debian at 23 MB/s |
| Plain links | Blender 4.2 for macOS, a 3 MB test file | Home in 8 parallel pieces, byte-for-byte identical |
| Brave hand-off | A real click on a download link in Brave 154 | Caught, Brave's copy cancelled, TorrANT finished it |
| Signed-in downloads | A test server that records request headers | Cookies, referrer and browser name all arrived |
| TorrANT closed | Helper run with no app listening | Says so, and Brave keeps the download |
| Same-name files | A download whose name already existed in Downloads | Saved as `name.1.ext`, old file untouched |
| Keep-awake | Downloads started, then finished | Mac held awake, then released: *"All quiet. The Mac can sleep again"* |
| Dock icon | Fresh build, app launched | The sketched ant, not a blank tile |

**Not yet checked by hand:** the clipboard banner, magnet links clicked in a browser, notifications, the
Ant Cam panel, picking single files from a torrent, and drag & drop. They're built; they haven't been
walked through on a real Mac yet.

---

## Limitations

- **Closing a MacBook's lid still sleeps it**, and downloads pause until it wakes. No app can stop
  lid-close sleep; only clamshell mode (power + external display) keeps going. Downloads resume on wake.
- **Not on the Mac App Store.** Apple doesn't allow torrent clients there, so TorrANT is a direct download.
- **aria2 comes from Homebrew for now.** Until it's bundled inside the app, TorrANT only runs on a Mac
  that has it installed.
- **Ad-hoc signed.** No Developer ID yet, so macOS asks before the first launch on another Mac.
- **Brave, not every browser.** The extension is Chromium-based and the helper is registered for Brave
  only. Chrome would work with one more registration; Safari would need its own extension.
- **Some downloads can't be handed over.** A link that works only once, or a file you get by submitting a
  form, fails when TorrANT asks for it again. Switch the extension off for that one download.
- **Cookies wait on disk until a download finishes.** aria2 saves unfinished downloads, with their
  headers, in TorrANT's folder in your Library, so a signed-in download can resume after a restart.
- **The sketched ant breathes.** Its idle animation costs about 9% CPU while the window is open.
- **Two display bugs:** the Anthill shows "in 0 sec." for every arrival, and a torrent fetched from a link
  leaves its `.torrent` file listed in the Anthill as if it were a download.

---

## Credits and licences

| Part | Licence |
|---|---|
| [aria2](https://github.com/aria2/aria2), the download engine | GPL-2.0, run as a separate program |
| [Bricolage Grotesque](https://fonts.google.com/specimen/Bricolage+Grotesque), headings | SIL Open Font License 1.1 |
| [Figtree](https://fonts.google.com/specimen/Figtree), body text | SIL Open Font License 1.1 |
| [Caveat](https://fonts.google.com/specimen/Caveat), the handwritten notes | SIL Open Font License 1.1 |
| Debian, Blender, *Sintel*, *Big Buck Bunny* (screenshots only) | Free software and Creative Commons films, used as test downloads |

The sketched ant, the icon and every screen are drawn in code in this repo.

---

## Why it is built this way

- **A real engine instead of a homemade one.** BitTorrent and segmented HTTP are full of edge cases that
  aria2 has handled for years. TorrANT's job is the colony, not the protocol. [ADR 0001](docs/adr/0001-aria2-as-the-engine.md).
- **Brave cancels last.** A download is only taken away from Brave after TorrANT confirms it has it, so a
  crash or a closed app can't lose a file. [ADR 0002](docs/adr/0002-brave-hand-off-over-native-messaging.md).
- **Numbers on layers, not views.** Smooth, honest numbers mattered enough to move them off SwiftUI's
  redraw path. [ADR 0003](docs/adr/0003-live-numbers-on-layers.md).
- **Never resume a stranger's file.** aria2 resumes only from its own progress files, never from a
  same-named file it finds lying around. [ADR 0004](docs/adr/0004-never-resume-a-file-we-did-not-start.md).
- **Awake only while working.** Holding the Mac awake is a cost to the user, so it's held only while
  something is downloading or queued, never for seeding.

---

## Roadmap

The full design has ten screens; these are the ones still to build.

| Screen | What it adds |
|---|---|
| **Taste Test** | Checks what came home before it's opened: safe or poison |
| **Step Aside** | Smart bandwidth: slow down when you're on a call, a night shift from 1 to 7 AM, gentle on a hotspot |
| **Colony Report** | A weekly report of what the ants carried, with badges |
| **Extra Crews** | Mirrors: pull one file from several places at once |
| **Already in the Anthill** | Spots a download you already have before fetching it again |
| **Foraging Routes** | RSS feeds, GitHub releases and a watch folder that send ants out on their own |
| **Storage Chambers** | Sorts arrivals into folders by kind |

Also next: aria2 bundled inside the app, a Developer ID signature, Chrome support, and pausing the ant's
idle animation when the window isn't in front.
