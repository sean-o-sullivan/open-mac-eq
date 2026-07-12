# Parametric EQ DSP core results

Date: 2026-07-11

## Scope

This phase deliberately separates DSP correctness from Core Audio routing. `BiquadDSP.swift` contains pure coefficient design, complex response evaluation, phase unwrapping, and an offline transposed-direct-form-II cascade. It imports Foundation only and has no Core Audio dependency.

Implemented minimum-phase biquads:

- peaking/bell
- low shelf
- high shelf
- low pass
- high pass
- notch

All coefficients use the RBJ Audio EQ Cookbook equations, are calculated in `Double`, normalized by `a0`, checked for finite values, and rejected unless the denominator passes the second-order Jury stability conditions. Shelf bandwidth uses the Q form of RBJ `alpha`; the eventual editor must label this field Q rather than shelf slope S.

The response evaluator uses the same normalized coefficients as processing:

```text
Htotal(z) = 10^(preampDb/20) * product(Hband(z))
magnitudeDb = 20 * log10(abs(Htotal))
phase = unwrap(arg(Htotal))
```

Bands are cascaded. No band outputs are summed in parallel.

## Automated verification

Final result: **14 passed, 0 failed, 0 skipped** on macOS 26.0.1 / arm64.

After profile/editor/import tests were added, the complete project suite reached **26 passed, 0 failed, 0 skipped**. The 14 tests described here are the DSP/routing subset.

DSP-specific coverage includes:

- fixed 48 kHz RBJ golden coefficients for a +3 dB, 1 kHz, Q 1 peaking filter
- fixed Butterworth-Q 5 kHz low-pass golden coefficients
- response anchors for all six filter types
- explicit regression proving two +3 dB coincident peaks cascade to +6 dB, not the approximately +9.02 dB produced by incorrect parallel summing
- offline impulse response against the direct difference equation
- independent state for left/right channels
- finite/stable designs across 20 Hz–20 kHz, Q 0.1–20, and gain ±24 dB
- invalid-parameter rejection
- C real-time bridge impulse processing
- exact live-update crossfade behavior

## Real-time implementation

`RealtimeBridge.c` owns a fixed-capacity engine allocated before audio starts:

- maximum 64 bands
- maximum 8 channels
- independent transposed-direct-form-II state for every band/channel
- two complete filter banks for old/new configurations
- atomic, fixed-size coefficient mailbox
- generation-checked publication so the callback cannot consume a partial update
- 1,024-frame default crossfade for parameter and structural changes
- Float64 coefficient/state math with Float32 Core Audio I/O
- finite-output guard

The render callback performs no heap allocation, locks, logging, file I/O, JSON work, or UI dispatch. When a new configuration arrives, the inactive bank is reset and both banks run during the bounded crossfade. Further UI changes coalesce in the mailbox and the newest snapshot is applied after the current crossfade completes.

Live diagnostics now report:

- last and maximum callback processing duration
- Core Audio processor-overload notifications
- applied DSP configuration count
- active band count and remaining crossfade frames
- non-finite outputs
- existing route timestamp delta and format mismatches

## Live AirPods validation

Result: the DSP-enabled 128-frame build launches and produces smooth, audible user-controlled EQ changes. Frequency sweeping was user-confirmed with no clicks, while processor-overload, non-finite-output, and format-mismatch counters all stayed at zero.

Still record/complete:

- run 10 and 32 sections during continuous playback
- record last/maximum callback processing duration
- confirm processor overloads, non-finite outputs, and format mismatches remain zero
- confirm the tap-to-output timestamp delta remains near the pass-through result
- soak at 128 frames for at least 30 minutes

AirPods still report 7,680 frames / 160 ms of their own Bluetooth device latency. That baseline is separate from the measured EQ route overhead and means this v1 is suitable for music listening, not live monitoring.
