# Architecture

Glim is one SwiftPM package with two products: `GlimCore`, a library holding everything that touches hardware or holds state, and `Glim`, the app: a menu bar menu and a window. The app is SwiftUI; `GlimCore` imports neither SwiftUI nor AppKit.

```
┌ Glim (app) ──────────────────────────────────────────────────────────────┐
│ GlimApp · AppDelegate · AppPresence · MainWindowController               │
│ MenuContentView · MonitorSectionView · MainWindowView · Settings         │
└───────────────┬──────────────────────────────────────────────────────────┘
                │ observes (Observation), calls set / refresh / confirm
┌ GlimCore ─────▼──────────────────────────────────────────────────────────┐
│ State     MonitorManager ─owns─▶ Monitor ─owns─▶ DeviceControl, InputSelector │
│              │ MonitorPlatform (protocol)         │ ControlBackend (closures)   │
│ Hardware  ┌──▼───────────────┐   ┌───────────────▼──┐   ┌──────────────┐  │
│           │ DisplayRegistry  │   │ DDCChannel actor │   │ CoreAudio    │  │
│           │ DisplayService-  │   │  └ DDCBus        │   │ Output actor │  │
│           │ Notifier (IOKit) │   │    └ IOAVService │   │              │  │
│           └──────────────────┘   └──────────────────┘   └──────────────┘  │
│ Protocol  DDC framing · VCPRequest · CapabilitiesRequest · MonitorCapabilities │
└──────────────────────────────────────────────────────────────────────────┘
```

## Layers and boundaries

| Layer | Where | Rule |
| --- | --- | --- |
| Presentation | `Sources/Glim` | Talks to `MonitorManager`, `Monitor` and the controls only. It never sees a VCP code, an IOKit object or an audio device ID. |
| State | `Sources/GlimCore/State`, `Model` | `@MainActor @Observable` classes. Decide what is shown, when to write and when to read. |
| Hardware | `Sources/GlimCore/DDC`, `Transport`, `Audio` | Actors and pure functions. Encode, decode, retry and time the protocol; nothing about UI. |

Three protocols are the seams that make the core testable without a monitor:

- `DDCBus` writes one frame and reads raw bytes. `IOAVServiceBus` is the real one; the tests use a byte-level simulated display that checks every checksum.
- `DDCDevice` (an actor protocol) reads and writes VCP codes. `DDCChannel` is the real one.
- `MonitorPlatform` provides discovery, channel creation, audio devices and change notifications. `LivePlatform` is the real one; `FakePlatform` drives the manager in tests.

`ControlBackend` is a pair of closures (read, write). It lets one `DeviceControl` type serve DDC levels, DDC choices and CoreAudio volume alike.

## State

`MonitorManager` owns the list of `Monitor`s. `Monitor` owns its controls. Nothing else holds state: values always come from the monitor, and `UserDefaults` holds only which rows the menu shows, where Glim appears (menu bar, Dock) and the window's frame.

**`DeviceControl<Value>`** is where the slider rules live:

- `value` is what the UI shows. A user change sets it at once (optimistic). `deviceValue` is the last value actually read.
- At most one write is in flight. Changes arriving meanwhile replace a single pending value. A drag therefore sends the first value, then the newest one each time the bus is free, and the queue can never grow. A value equal, after quantization, to the last one written is not sent.
- When writes stop, and the user is not dragging, the control reads the value back after `settleDelay` (800 ms), so the slider ends up where the monitor actually is.
- A generation counter is taken when a read is issued. The result is applied only if no change, pending write or drag happened since, so a slow reply cannot overwrite newer intent. The same rule applies to a failed read.
- A failed write shows a warning on that control only, and the warning stays after the read-back has put the slider back to the device's value, so a rejected change never vanishes silently. Write failures never change the monitor's status: only reads decide that, so one dropped write cannot swap the controls out from under a drag.
- No write is sent before the first successful read: until then the device's range, and whether it answers at all, are unknown.
- `endInteraction()` ends a drag the UI can no longer finish. SwiftUI never reports the end of a drag on a slider it removed, so the menu calls it on every control whenever it opens or closes, the window when it closes or is minimised, and each slider when SwiftUI removes it.

**`InputSelector`** only *stages* a choice (`request`). The write happens on `confirm()`, which the menu and the window call from an explicit button that is deliberately not the default action. Its underlying control is internal to `GlimCore`, so nothing else can write an input. A staged choice is dropped when the menu closes, and when the window closes or is minimised.

**`Monitor`** picks a profile from the EDID identity. The HP E27m G4 has a tested profile, with input switching marked untested; anything else is built from its capabilities string, and a control is kept only if it answers a read. Its `status` (connecting, ready, not responding) comes from the outcome of DDC reads. Audio failures do not count, because they concern another device, and the USB speakers stay usable while DDC is silent. On a reconnect its DDC controls are removed at once and rebuilt on the new channel, and every control it replaces is invalidated, so none stays on screen dead or keeps writing in the background.

**`MonitorManager`** rescans when IOKit, AppKit or a wake says displays changed, debounced by 750 ms, and one scan at a time. It keys monitors by identity, so a monitor that comes back with a new transport keeps its object and gets a new channel. It keeps **one channel per transport**: when a monitor object is replaced on the same bus (for instance once its EDID is published and its key changes), the old and the new one share that channel, so their traffic is still serialised. Monitors that are gone are invalidated: every task is cancelled, and an operation still queued on the channel sends nothing (see *Concurrency*).

## Menu, window and Dock

The menu and the main window are two views of the same `MonitorManager` and the same `Monitor` objects. Neither keeps a copy of any value, so a change made in one shows in the other at once, and each monitor still has exactly one channel.

`MainWindowController` owns the window in AppKit rather than as a SwiftUI `Window` scene. The app delegate opens it on reopen and at launch (unless macOS started Glim at login), which a scene doesn't allow, and before macOS 15 a scene's launch and restoration can't be turned off. `AppPresence` keeps `LSUIElement`'s menu-bar-only policy except while the window is open, when the settings ask for the Dock, or when the menu bar icon is hidden.

## Concurrency

- **Each monitor's `DDCChannel` is an actor whose executor is its own `DispatchSerialQueue`.** The IOAVService calls are synchronous, and the protocol needs pauses between them, so a transaction (request, pause, reply) runs start to finish with blocking sleeps and **no suspension point**. Actors are reentrant, but nothing can run inside a transaction because it never awaits; and the blocking happens on the channel's own thread, never on the main thread or the Swift concurrency pool.
- Reading the capabilities string takes about 3 s. It is one transaction per fragment, so a slider write can run between fragments.
- **`CoreAudioOutput`** is an actor on its own queue too: CoreAudio property calls are IPC to the audio server.
- **State is on the main actor.** Its methods await the hardware actors, so the main thread is free while the bus is busy.
- **No polling.** Glim reads when a monitor connects, each time the menu opens or the window becomes key (at most once every 2 s per monitor), and after writes settle. Idle CPU is zero.
- **Timeouts and cancellation.** A DDC transaction cannot be interrupted, so `withDeadline` races it against a timer with a first-wins continuation and cancels whichever side loses. The caller gets `.timedOut` after 5 s. Cancelling the caller cancels the operation and returns at once. Every `DDCChannel` operation checks for cancellation before it touches the bus, so an operation whose caller timed out or went away, still queued behind a stuck one, sends nothing when its turn comes: a write the UI reported as failed can never land later. An overrunning transaction itself keeps its queue until it finishes.
- **Task ownership.** Each control owns at most one writer task and one reconcile task. Each monitor owns its configuration task, and the manager owns its pending rescan. All of them capture `self` weakly and are cancelled on `invalidate()` or `stop()`.

### Escape hatches, and why each is sound

There is no `@unchecked Sendable` and no `nonisolated(unsafe)` in the sources. Unsafe or unchecked constructs:

| Where | What | Why it is sound |
| --- | --- | --- |
| `IOAVService.swift` | `dlsym` plus `unsafeBitCast` to `@convention(c)` types | The function types mirror the C prototypes used by m1ddc and `tools/glim-cli`. Resolving at run time is what allows a graceful failure. |
| `IOAVService.swift` | `Unmanaged` for the IOAVService CF object | `Create` returns +1, taken once with `takeRetainedValue`. Calls pass it unretained while `self` holds it. |
| `DisplayServiceNotifier.swift` | `self` as the IOKit refCon, `MainActor.assumeIsolated` in the callback | The notification port's queue is `.main`, so the callback is on the main thread. The refCon holds a +1 reference, released by `stop()` only after the port is destroyed, so a notifier nobody stopped leaks instead of dangling. |
| `AppDelegate.swift`, `WindowKeyObserver.swift` | `MainActor.assumeIsolated` in `NotificationCenter` blocks | The observers are registered with `queue: .main`. |

## Hardware lifecycle

1. **Discovery** (`DisplayRegistry`) reads the IORegistry only: external `DCPAVServiceProxy` entries, joined to framebuffer EDIDs by display pipe. See [protocol.md](protocol.md).
2. **A channel opens lazily**, on its first transaction, through `IOAVServiceCreateWithService`. After 3 consecutive transport failures it is dropped and reopened on the next operation.
3. **Configuration** builds the controls for the profile and reads them. Volume and mute are attached when the monitor's USB Audio device is found, and re-checked on every refresh, because USB enumerates after the display does.
4. **Reconnect**: a new proxy for a known identity rebuilds the controls on a new channel.
5. **Disconnect**: the monitor is invalidated and dropped. ARC releases its channel, which releases the IOAVService.
6. **Quit**: the app delegate stops the manager: it stops observing, cancels its tasks and invalidates every monitor.

## Errors

| Type | From | Meaning |
| --- | --- | --- |
| `DDCError` | channel and transport | `noReply`, `writeFailed` / `readFailed` (IOReturn) and `timedOut` are transient. `unsupported(code)`, `refused(code)` (a code outside `DDCChannel.writableCodes`) and `transportUnavailable` are final. |
| `AudioError` | CoreAudio output | `deviceUnavailable`, `notSupported`, or a CoreAudio status. |
| `ControlFailure` | `DeviceControl` | A message for the UI, plus whether retrying may help. |

A control shows its failure as a warning symbol with the message as its tooltip. A monitor whose reads fail shows "Not responding" with a retry button. A code the monitor reports as unsupported removes that control.

## Tests

| Suite | Needs | Covers |
| --- | --- | --- |
| `DDCMessageTests`, `CapabilitiesTests` | nothing | framing and parsing against frames captured from the HP |
| `DDCChannelTests` | nothing | retries, timing, quirks and reopening, against a byte-level simulated display |
| `ChannelSafetyTests` | nothing | the write allow-list, operations dropped after a timeout or cancellation, no overlapping transactions (the simulator flags any), the verified timing constants |
| `DeviceControlTests`, `InputSelectorTests`, `ControlRecoveryTests` | nothing | coalescing, stale reads, reconciliation, drags and abandoned drags, failure handling, timeouts and invalidation, with gated mocks |
| `MonitorManagerTests`, `LifecycleTests` | nothing | discovery, identity, reconnects, one channel per transport, identical and unidentified monitors, audio association, debouncing |
| `DiscoveryTests` | nothing | joining transports to framebuffers, including pairing by elimination |
| `RenderTests` | a GUI session | the menu, the whole window (frame and toolbar included) and the settings, in every state, light and dark, offscreen |
| `MainWindowTests`, `AppPresenceTests` | a GUI session | one window, launch and reopen, the Dock rule, interactions ended on close, and the window and the menu following each other through their real sliders |
| `HardwareTests` | an HP E27m G4, `GLIM_HARDWARE_TESTS=1` | the real thing; every write is reversible and restored |

See [development.md](development.md) for how to run each.
