# Profiles and parametric editor

Date: 2026-07-11

## Profile format

Named profiles use schema-versioned JSON containing:

- stable profile UUID
- exact Core Audio device UID
- input preamp in dB
- arbitrary ordered band array
- optional reference-curve name and frequency/gain points

Each band has its own UUID, enabled state, type, frequency, gain, and Q. The current real-time safety ceiling is 64 bands. Unknown fields at the supported schema version are ignored; unsupported newer schema versions fail explicitly.

The app stores profiles by UUID—not display name—under:

```text
~/Library/Application Support/openEq/Profiles/<UUID>.json
```

Writes use atomic file replacement. Rename changes only the name and preserves the UUID. Load, save, rename, list, and delete are covered by automated tests.

## Device association

Device associations are keyed by the exact Core Audio device UID and store:

- last-used profile UUID
- Ask / Always Apply / Never preference

When a saved device UID newly becomes the default output, the app either offers the last profile, applies it, or does nothing according to that preference. Display names are never used as persistence keys. Re-pairing Bluetooth headphones or reconnecting some interfaces may produce a different UID and intentionally does not bind silently.

## Editor

The SwiftUI editor supports:

- add/delete/enable/reorder for bell, low shelf, high shelf, low pass, high pass, and notch bands
- graph node horizontal drag for logarithmic frequency
- graph node vertical drag for gain-bearing types
- scroll wheel over a node for Q
- Shift-modified fine drag/scroll
- exact numeric frequency, gain, and Q fields
- input preamp control
- combined magnitude response from the exact DSP coefficients
- optional unwrapped phase overlay
- selected/disabled band state
- live coefficient publication using the tested dual-bank crossfade
- paste/import of Equalizer APO-style text profiles
- JSON import/export
- bundled AirPods Pro 3 Songbird JM-1 six-band preset

## Reference curves

CSV, TSV, semicolon-separated, and whitespace-separated text files are accepted. The first two numeric columns are frequency in Hz and gain in dB. Headers and comment lines are ignored; valid points are sorted, duplicate frequencies keep the final value, and fewer than two points are rejected.

Reference points are visual only. They are drawn as a dotted line with a logarithmic frequency axis and never alter DSP coefficients.

## Verification

Complete project test result: **28 passed, 0 failed, 0 skipped** on macOS 26.0.1 / arm64.

The AirPods Pro validation route completed the manual editor/DSP pass. Generalized device selection is automated-test covered; additional physical output types still benefit from route-specific manual validation:

- create, save, rename, reload, and delete a profile
- add one of every filter type and verify numeric edits match graph nodes
- drag/scroll while audio plays and confirm smooth changes
- import a known target curve and confirm dotted overlay only
- reconnect or switch output devices and exercise Ask/Always/Never behavior
- sleep/wake once while DSP is active and confirm fail-open stop plus clean refresh

The AUHAL fallback remains intentionally unimplemented for v1. Same-cycle private aggregate routing passed on the AirPods Pro validation route. Other compatible Core Audio outputs use the same path; incompatible formats fail safely rather than switching to a second routing architecture.
