# Security and privacy

## Audio and permissions

openEq requests macOS System Audio Recording permission because Core Audio process taps require it. The app does not request microphone, camera, contacts, location, accessibility, automation, or network permissions.

Audio is processed locally in the real-time callback and is not written to disk or transmitted. The project contains no telemetry, analytics SDK, updater, HTTP client, crash uploader, advertising SDK, or account system.

## Local data

Profiles and device associations are stored under:

```text
~/Library/Application Support/openEq/
```

A device association contains the Core Audio device UID and the selected profile UUID. It stays local unless the user explicitly exports or shares it. Exported profiles should be reviewed before publication because a profile's `deviceUID` may identify a personal device pairing.

## Fail-open behavior

- The direct route is muted only while the process tap is actively consumed.
- Closing EQ, changing or disconnecting the output device, changing sample rate, sleeping, or quitting destroys the tap.
- A second app instance is prevented from starting a competing global tap.
- Invalid, unstable, or non-finite filter configurations are rejected.

## Real-time safety

The render path uses fixed-capacity memory and C11 atomics. It performs no allocation, locks, logging, file operations, JSON parsing, or UI work. Output samples are checked for finiteness before conversion to Float32.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting/security-advisory feature for the repository. Do not include personal device identifiers, captured audio, access tokens, or private profiles in a public issue.

## Public-repository hygiene

The repository intentionally excludes:

- build products and derived data
- locally packaged applications and disk images
- Xcode user state
- saved profiles and device associations
- screenshots containing personal device names, Core Audio UIDs, usernames, or event logs
- credentials, signing identities, and notarization secrets
