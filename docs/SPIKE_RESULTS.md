# Core Audio tap hardware-spike results

> Reliability follow-up, 2026-07-12: the clean 128-frame validation below was reproducible, but a later 33-minute Bluetooth soak recorded 19 intermittent Core Audio overloads. The product now defaults Bluetooth routes to 256 frames, retains 128 frames for non-Bluetooth outputs, monitors callback progress in menu-bar-only mode, and can rebuild at 512 frames or fail open to direct audio. The original spike evidence remains below for traceability.

Date: 2026-07-11

## Test system

- macOS 26.0.1
- Xcode 16.4 / macOS 15.5 SDK
- Apple-silicon Mac
- AirPods Pro 3 over Bluetooth
- AirPods stream: 48,000 Hz, stereo, 32-bit Float PCM, packed/interleaved

## Architecture result

The recommended no-driver path works:

```text
device-specific process tap
  -> private aggregate input
  -> same aggregate I/O callback
  -> AirPods output subdevice
```

The tap excludes the EQ process and uses `CATapMutedWhenTapped`. System-wide audio from another application was captured, muted on its direct path, copied unchanged, and heard through AirPods. No virtual HAL driver, AudioDriverKit extension, kernel extension, or AU plug-in was installed.

## Measurements

| Physical + aggregate buffer | Timestamp delta | Format mismatches | Audio result |
|---:|---:|---:|---|
| 512 frames | 21.333 ms | 0 | Working and stable |
| 256 frames | Not retained before window close | 0 observed | Working |
| 128 frames | **5.333 ms** | **0** | **Working and stable** |

Clean 128-frame capture:

- 12,069 callbacks
- 1,544,832 frames copied
- 128 frames in the last callback
- one interleaved input buffer and one interleaved output buffer
- 5.333 ms input-to-output timestamp delta
- zero format mismatches
- user-confirmed uninterrupted documentary playback

The driver reports 7,680 frames (160 ms at 48 kHz) of AirPods device latency and zero safety-offset frames. That is Bluetooth/device latency, not EQ-added latency. The measured tap-to-output delta is the relevant added route value.

The normal AirPods buffer was 512 frames. Core Audio reported a permitted range of 15–960 frames and accepted 128 frames for both the physical device and private aggregate. The spike restores the original 512-frame setting on Stop; readback after stopping confirmed restoration.

## Requirement verdict

- System-wide AirPods-only interception: pass.
- No driver/kext/system extension: pass.
- Native 48 kHz processing with no app resampling: pass.
- Float32 format preserved: pass.
- Added latency below approximately 10 ms: pass at 128 frames (`5.333 ms`).
- Fail-open path: pass on Stop/process exit/output change by design and observed direct-audio restoration.

## Automated verification

The final macOS test run passed all four tests with zero failures or skips. It covers AirPods classification, frame and nanosecond timing conversion, and the C real-time bridge's planar-to-interleaved copy path.

## Discovered failure mode

An initial 128-frame attempt produced silence while a stale second spike window/instance was present. A clean retest with exactly one process worked. The spike now blocks a second instance from starting audio processing. The product must retain that invariant and never allow two active global device taps for the same output.

## Remaining product tests

- Long-duration 128-frame underrun/overload soak test.
- Sleep/wake and rapid AirPods disconnect/reconnect.
- Default-output switching while processing.
- AirPods microphone activation and Bluetooth profile/format change.
- Spatial Audio/head-tracking behavior.
- Protected/DRM playback and system alert sounds.
- DSP-enabled latency and CPU load with a large band count.
