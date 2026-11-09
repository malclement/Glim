# Development

## Requirements

- A Mac with Apple silicon, on macOS 14 or later. DDC/CI goes through an interface Intel Macs don't have.
- Swift 6.1 or later. The Xcode Command Line Tools are enough (`xcode-select --install`), and Xcode is optional: open `Package.swift` to work in it.
- For the hardware tests, an HP E27m G4 connected over USB-C.

## Common tasks

```sh
make test            # unit, simulated-hardware and render tests; no monitor needed
make check           # the same with warnings as errors (what CI runs)
make run             # build dist/Glim.app and open it
make hardware-test   # against a connected HP E27m G4
make help            # everything else
```

`make app` builds `dist/Glim.app`: a release build, the icon, and an ad-hoc signature with the Hardened Runtime. Bare `swift build` builds the executable but no app bundle. Packaging and signing are covered in [release.md](release.md).

## Layout

| Path | Contents |
| --- | --- |
| `Sources/GlimCore/DDC` | DDC/CI framing, the capabilities parser, and the per-monitor channel actor |
| `Sources/GlimCore/Transport` | IOAVService binding, IORegistry discovery, IOKit notifications |
| `Sources/GlimCore/Audio` | The monitor's USB Audio volume and mute, through CoreAudio |
| `Sources/GlimCore/State`, `Model` | Monitors, controls, profiles, the manager |
| `Sources/Glim` | The SwiftUI app |
| `Tests/GlimCoreTests` | Protocol, channel, state and hardware tests; the captured fixtures |
| `Tests/GlimAppTests` | Offscreen renders of every view state |
| `Tests/GlimTestSupport` | Simulated displays and mocks shared by both suites |
| `Support` | Info.plist and entitlements |
| `scripts`, `.github/workflows` | Icon, DMG, notarization and CI |
| `tools/glim-cli`, `tools/macos-probe` | The research CLI and read-only probes |

[architecture.md](architecture.md) explains how the pieces fit together.

## Tests

**Unit and simulated hardware.** `make test` runs them all in a few seconds, no monitor needed. The DDC tests check the encoder and decoder against frames captured from the real monitor (`Tests/GlimCoreTests/Fixtures`), and run the channel against a simulated display that validates every checksum and can misbehave the way the hardware does. The state tests hold operations at gates, so coalescing and stale-read behaviour is tested deterministically rather than by timing.

**Renders.** `RenderTests` draws each view, in every state and in light and dark, in an offscreen window. This draws real AppKit controls and needs no Screen Recording permission. To look at the results:

```sh
GLIM_RENDER_DIR=/tmp/glim-renders swift test --filter RenderTests
open /tmp/glim-renders
```

**Hardware.** `make hardware-test` sets `GLIM_HARDWARE_TESTS=1` and runs `HardwareTests` against a connected HP E27m G4. It reads the identity and capabilities, and the Mac's light sensor and built-in brightness (read only, `SensorHardwareTests`), then round-trips brightness, contrast, a 30-step drag, the color presets and temperature (from the factory 6500 K and back to it), and the USB Audio volume and mute. These are only writes the reverse engineering verified as reversible, and each one is restored even when an expectation fails. It never touches the input, power or any vendor code. To check that the monitor is back where it was, compare `./glim scan` (after `make glim`) before and after: only 0xC0, the usage-hour counter, should change.

## Running a development build

`make run` opens `dist/Glim.app`. Glim refuses to run twice, so quit any installed copy first.

To keep a test build apart from an installed copy, give it its own bundle identifier:

```sh
ditto dist/Glim.app /tmp/glim-qa/Glim.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.malclement.Glim.qa" /tmp/glim-qa/Glim.app/Contents/Info.plist
codesign --force --options runtime --sign - /tmp/glim-qa/Glim.app
open /tmp/glim-qa/Glim.app
```

Afterwards, unregister it from LaunchServices, or `open` can later resolve the identifier to a deleted copy and hang:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /tmp/glim-qa/Glim.app
```

## Logs

Glim logs to the unified log under the subsystem `io.github.malclement.Glim`, with the categories `ddc`, `discovery`, `audio`, `state` and `app` (the window and the Dock). Every DDC frame is logged at debug level, which macOS shows live but does not keep:

```sh
log stream --level debug --predicate 'subsystem == "io.github.malclement.Glim" AND process == "Glim"'
```

Filter on `process`: `swift test` logs under the same subsystem.

## The research tools

`make glim` builds `./glim`, the C CLI that the reverse engineering used: `glim caps`, `glim scan --all`, `glim -v get 10`. It is the quickest way to see what a monitor answers. It refuses writes that can blank the screen or lock the monitor out unless given `--force`; read [controls.md](controls.md) before using that. `make probes` builds the read-only macOS probes in `tools/macos-probe`.
