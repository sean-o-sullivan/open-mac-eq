# openEq 1.0 local release

Date: 2026-07-12

## Artifacts

- `dist/openEq.app`
- `dist/openEq-1.0.dmg`
- `dist/openEq-1.0.zip`

SHA-256:

```text
9dfe88d4c7510614310316723dff780a1caf146b91cd2a17d8f861fede3ad85e  openEq-1.0.dmg
1bee104182c66c8b69b001f453e629ada294e2ef716cbcc8e70e9912a6501365  openEq-1.0.zip
```

The app uses hardened runtime and ad-hoc signing for local use. `codesign --verify --deep --strict` passes. Public distribution requires rebuilding with a Developer ID Application certificate and submitting the result for notarization.

The source and binary package are distributed under the MIT License. The license is embedded in `openEq.app` and included at the root of the DMG.

## Included profile

**AirPods Pro 3 — JM-1 10-band**

- intended for AirPods Pro 3 with ANC enabled
- preamp: -3.8 dB
- ten RBJ peaking filters
- source file bundled inside the app
- exact preamp/frequency/gain/Q import verified by automated test

This is a population-average measurement correction, not a personalized hearing profile.

## Background behavior

- Dock/Cmd-Tab-hidden menu-bar agent
- `Open EQ` / `Close EQ` primary actions
- processing continues after the editor window closes
- optional launch at login
- optional automatic start when an exact saved output-device UID and profile are ready
- sleep destroys the tap and fails open before wake-time state refresh

## Verification

- 28 automated tests passed; zero failed/skipped
- Release app compiled for arm64, macOS 14.2+
- package signature verifies with strict/deep checks
- installed application launches from `/Applications/openEq.app`
- bundle display name is `openEq`
- bundle identifier is `app.openmaceq.openEq`
- `LSUIElement = true`; no Dock or Command-Tab entry
- menu-bar controller appears and the editor remains accessible
- any live macOS default output is eligible; incompatible Core Audio stream formats fail safely
