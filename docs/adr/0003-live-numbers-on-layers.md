# ADR-0003: Live numbers on Core Animation layers, never backwards

**Date**: 2026-11-07
**Status**: accepted
**Deciders**: Sidhyarth

## Context

A downloader is mostly numbers: speeds, sizes, time left, progress. aria2
reports them four times a second, so plain labels jump in steps and sometimes
tick down when a sample is noisy. The design calls for odometer-style digits
that move every frame and never run backwards.

## Decision

Keep the last two samples per download and interpolate between them every
display frame (`Sources/TorrANT/Live.swift`). Draw the moving parts on Core
Animation layers driven by a display link (`Sources/TorrANT/LiveLayers.swift`),
outside SwiftUI's view updates. Downloaded sizes are clamped so they only grow.
The app state only changes an observed value when it really changed, so an idle
window doesn't redraw at all.

## Alternatives Considered

### SwiftUI `TimelineView` redrawing the labels
- **Pros**: plain SwiftUI, no layers.
- **Cons**: about 45% CPU on its own in the first build.
- **Why not**: a downloader that heats the Mac isn't doing its job.

### Show the raw four-times-a-second numbers
- **Pros**: no work at all.
- **Cons**: jumpy, and numbers that go down read as a bug.
- **Why not**: the live feel is half of the design.

## Consequences

### Positive
- Smooth, honest numbers at a small fraction of the `TimelineView` cost.

### Negative
- Two drawing systems (SwiftUI and layers) to keep visually in step.

### Risks
- The sketched ant's idle animation still costs about 9% CPU while the window
  is open; it should pause when the window isn't in front.
