# Architecture decisions

Short records of the choices that shape TorrANT: what I decided, what I
turned down, and what it costs. Each one is a few minutes' read and points at
the code that carries it out. If you are wondering "why does it do it this
way?", the answer is probably here.

| # | Decision | Date |
|---|---|---|
| [0001](0001-aria2-as-the-engine.md) | aria2 carries the downloads; the app is the colony | 2026-11-07 |
| [0002](0002-brave-hand-off-over-native-messaging.md) | Brave hands downloads over by native messaging, and cancels last | 2026-11-08 |
| [0003](0003-live-numbers-on-layers.md) | Live numbers on Core Animation layers, never backwards | 2026-11-07 |
| [0004](0004-never-resume-a-file-we-did-not-start.md) | Never resume a file TorrANT didn't start | 2026-11-08 |

New decisions get the next number. A decision that is replaced is marked
superseded rather than deleted, so the history of why stays readable.
