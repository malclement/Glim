# Contributing to Glim

Thanks for helping. Glim is small on purpose: a native menu bar app that talks to monitors over DDC/CI. The bar for changes is that they are correct on real hardware and safe for it.

## Setting up

You need a Mac with Apple silicon on macOS 14 or later, and Swift 6.1 or later; the Xcode Command Line Tools are enough. Then:

```sh
make test   # a few seconds, no monitor needed
make run    # builds dist/Glim.app and opens it
```

[docs/development.md](docs/development.md) covers the layout, the three kinds of tests, logs and development builds. [docs/architecture.md](docs/architecture.md) explains the design. Read its *State* and *Concurrency* sections before changing `DeviceControl` or `DDCChannel`.

## Before you open a pull request

- `make check` passes: everything builds and every test passes with warnings as errors, which is what CI runs.
- New behaviour has a test, and the test fails without the change. The simulated display (`Tests/GlimTestSupport`) can reproduce most hardware behaviour, including shifted reads, dropped writes, silence and the read-0-after-set quirk.
- If you changed a view, look at it: `GLIM_RENDER_DIR=/tmp/r swift test --filter RenderTests` draws every state in light and dark.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org): `feat(core): …`, `fix(app): …`, `docs: …`.
- The description says what you ran on real hardware, and on which monitor, or that you didn't.

## Code

- Swift 6 language mode with strict concurrency; keep it free of warnings. Don't silence the checker with `@unchecked Sendable` or `nonisolated(unsafe)`. If a construct really is safe, explain why where you write it, as [architecture.md](docs/architecture.md#escape-hatches-and-why-each-is-sound) does for the existing ones.
- Nothing that talks to hardware runs on the main actor. Each monitor's transactions run on its own `DDCChannel`.
- No force unwraps in hardware code. Errors are typed (`DDCError`, `AudioError`) and reach the UI as a message.
- Comments explain *why*, especially hardware behaviour that would otherwise look like a bug.

## Supporting another monitor

The most useful contribution, and the one that needs the most care: a wrong write can blank a monitor, lock it out of DDC/CI, or reset its settings.

1. Follow [Adding a monitor safely](docs/protocol.md#adding-a-monitor-safely): read before you write, write only standard reversible codes, restore what you change, and never send undocumented or vendor codes to see what happens.
2. Add a `MonitorProfile` in `Sources/GlimCore/Model/MonitorProfile.swift` with only the controls you verified, and match it on the EDID manufacturer and product code.
3. Add the monitor's capabilities string as a test fixture, plus a test that the profile matches.
4. In the pull request, list each control and how you verified it.

Monitors without a profile already get the standard controls their capabilities string lists. A report that one of those works, or doesn't, is valuable too: open an issue with **Settings › Displays › Copy Diagnostics** attached.

## Reporting bugs

Open an issue with what you did, what happened, and the diagnostics from **Settings › Displays › Copy Diagnostics** (they leave out serial numbers). For DDC/CI problems, a debug log helps:

```sh
log stream --level debug --predicate 'subsystem == "io.github.malclement.Glim" AND process == "Glim"'
```
