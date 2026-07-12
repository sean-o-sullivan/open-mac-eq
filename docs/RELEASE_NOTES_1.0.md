# openEq 1.0 local release

Date: 2026-07-12

## Artifacts

- `dist/openEq.app`
- `dist/openEq-1.0.dmg`
- `dist/openEq-1.0.zip`

SHA-256:

```text
0debe34258963e1dd7051a841d8871d17ae074d30992f875217dbe2de27f6f32  openEq-1.0.dmg
8ad29b2a4b224ab92f1dd8d56f43333f63eb9042ea6d99442f45b64d0dadb34b  openEq-1.0.zip
```

The app uses hardened runtime and ad-hoc signing for local use. `codesign --verify --deep --strict` passes. Public distribution requires rebuilding with a Developer ID Application certificate and submitting the result for notarization.

The source and binary package are distributed under the MIT License. The license is embedded in `openEq.app` and included at the root of the DMG.

## Included profile

**AirPods Pro 3 — Songbird JM-1 6-band**

- Songbird AutoEQ result for its AirPods Pro 3 L/R average against `JM-1 -10 dB Tilt`
- source measurement listening mode is not explicitly documented
- preamp: -3.9 dB
- six RBJ peaking filters
- source file bundled inside the app
- exact preamp/frequency/gain/Q import verified by automated test
- exact saved copies of the former bundled ten-band preset migrate automatically; customized profiles do not

This is a population-average measurement correction, not a personalized hearing profile.

## Background behavior

- Dock/Cmd-Tab-hidden menu-bar agent
- `Open EQ` / `Close EQ` primary actions
- processing continues after the editor window closes
- optional launch at login
- optional automatic start when an exact saved output-device UID and profile are ready
- sleep destroys the tap and fails open before wake-time state refresh
- Bluetooth/Bluetooth LE routes start at 256 frames; other transports start at 128
- health monitoring continues while the editor is closed
- overload bursts and callback stalls trigger a safer-buffer route rebuild
- repeated or failed recovery destroys the tap and restores direct audio
- diagnostics report output peak and samples above 0 dBFS

## Verification

- 35 automated tests passed; zero failed/skipped
- Release app compiled for arm64, macOS 14.2+
- package signature verifies with strict/deep checks
- installed application launches from `/Applications/openEq.app`
- bundle display name is `openEq`
- bundle identifier is `app.openmaceq.openEq`
- `LSUIElement = true`; no Dock or Command-Tab entry
- menu-bar controller appears and the editor remains accessible
- any live macOS default output is eligible; incompatible Core Audio stream formats fail safely
- complete macOS app-icon asset catalog compiled into `AppIcon.icns`
