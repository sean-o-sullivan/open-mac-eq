# openEq 1.0 local release

Date: 2026-07-12

## Artifacts

- `dist/openEq.app`
- `dist/openEq-1.0.dmg`
- `dist/openEq-1.0.zip`

SHA-256:

```text
34cd85cb9ec010c51c3fc449a7d5b9c2bb838850260abd903e00d720332c90b6  openEq-1.0.dmg
f695230fbb9ad238b51e3f13e389cb35753054ed47ddbbcf8c92eb0525d56c8f  openEq-1.0.zip
```

The app uses hardened runtime and ad-hoc signing for local use. `codesign --verify --deep --strict` passes. Public distribution requires rebuilding with a Developer ID Application certificate and submitting the result for notarization.

## Included profile

**AirPods Pro 3 — JM-1 10-band**

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
- optional automatic start when an exact saved AirPods UID and profile are ready
- sleep destroys the tap and fails open before wake-time state refresh

## Verification

- 27 automated tests passed; zero failed/skipped
- Release app compiled for arm64, macOS 14.2+
- package signature verifies with strict/deep checks
- installed application launches from `/Applications/openEq.app`
- bundle display name is `openEq`
- bundle identifier is `app.openmaceq.openEq`
- `LSUIElement = true`; no Dock or Command-Tab entry
- menu-bar controller appears and the editor remains accessible
