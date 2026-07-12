# openEq setup guide

## Install from a DMG

1. Open `openEq-1.0.dmg`.
2. Drag `openEq.app` onto the Applications shortcut.
3. Open `/Applications/openEq.app`, or press Command-Space and search for `openEq`.
4. If using an unnotarized local build, Control-click the app, choose **Open**, then confirm.
5. Grant **System Audio Recording** when macOS asks.

openEq is a menu-bar app. Its waveform icon appears at the top of the screen; it intentionally stays out of the Dock and Command-Tab switcher.

## Build from source

Requirements: macOS 14.2+, Xcode 16+, Apple silicon.

```sh
git clone https://github.com/sean-o-sullivan/open-mac-eq.git
cd open-mac-eq
xcodebuild \
  -project AirPodsEQSpike.xcodeproj \
  -scheme AirPodsEQSpike \
  -configuration Debug \
  -derivedDataPath .build \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For live system-audio permission behavior, opening the project in Xcode and selecting a local Development Team is the smoothest development workflow.

## Create a local app and DMG

```sh
./scripts/package-local.sh
```

Outputs:

```text
dist/openEq.app
dist/openEq-1.0.dmg
dist/openEq-1.0.zip
```

Set `DEVELOPER_ID_APPLICATION` to a Developer ID Application identity when signing for distribution. Notarization is a separate required step for a clean public binary release.

The app, DMG, and ZIP include the project's MIT license. The software is provided as is, without warranty; use it at your own risk.

## First run

1. Connect the headphones, speakers, or DAC you want to use.
2. Select that device as the macOS default output.
3. Open the openEq menu-bar icon and choose **Show Editor**.
4. Select or create a profile.
5. Choose **Open EQ** in the menu.
6. Confirm callbacks and processed frames increase.

Closing the editor window leaves processing active. Choose **Close EQ** to destroy the tap and restore direct audio.

## Load a profile

Options:

- Click **Load Songbird JM-1 preset** for the bundled AirPods Pro 3 correction baseline.
- Use **Profile I/O → Paste EQ text**.
- Import a `.txt` Equalizer APO-style profile.
- Import a versioned openEq `.json` profile.
- Enter frequency, gain, and Q directly in the band table.

Save the profile, then choose whether openEq should ask, always apply, or never auto-apply it for that exact Core Audio device UID. Profiles are device-specific, so changing outputs does not silently reuse another device's correction.

## Run in the background

- Enable **Launch at login** after installing openEq in `/Applications`.
- Enable automatic start only after saving a profile and selecting **Always apply last profile**.
- Use the waveform menu-bar icon to open/close EQ or show the editor.

Sleep stops processing and restores direct audio. Wake refreshes device/profile state and only restarts when saved settings make the action unambiguous.

## Troubleshooting

### No audio after opening EQ

- Ensure only one openEq instance is running.
- Choose **Close EQ**, then **Open EQ** again.
- Confirm the selected device is still the macOS default output.
- Check the status message for an unsupported format or buffer-size error.
- Quit other system-EQ or virtual-routing apps during diagnosis.

### System Audio Recording was denied

Open System Settings → Privacy & Security → Screen & System Audio Recording, enable openEq, then relaunch it.

### AirPods microphone/call changed the format

Using the AirPods microphone can change the Bluetooth profile, sample rate, or channel layout. openEq stops rather than silently resampling. Close the call/microphone client, restore stereo output, then choose **Open EQ** again.

### Another output device is rejected

openEq requires matching native-rate, 32-bit floating-point Core Audio tap/input/output streams. It does not insert a sample-rate converter. Some hardware or virtual devices may expose an incompatible layout; openEq reports the mismatch and restores direct audio.

### Launch at login fails

Move openEq into `/Applications` first. Launch-at-login registration is unreliable for temporary build or mounted-DMG paths.

### Gatekeeper blocks a local build

Control-click the app and choose **Open**. Public distribution should use Developer ID signing and notarization instead of asking users to bypass Gatekeeper.
