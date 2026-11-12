# Architecture

Glim is one SwiftPM package with two products: `GlimCore`, a library holding everything that touches hardware or holds state, and `Glim`, the app: a menu bar menu and a window. The app is SwiftUI; `GlimCore` imports neither SwiftUI nor AppKit.

```
┌ Glim (app) ──────────────────────────────────────────────────────────────┐
│ GlimApp · AppDelegate · AppPresence · MainWindowController · GlimStore   │
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
│ Also      Adaptive (AdaptiveController, LightSources) · Scenes · Support │
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

`MonitorManager` owns the list of `Monitor`s. `Monitor` owns its controls. Nothing else holds state: values always come from the monitor. `UserDefaults` holds which rows the menu shows, where Glim appears (menu bar, Dock) and the window's frame, and, through `GlimStore`, the scenes, each display's own name and menu choices, and the automatic brightness and evening warmth settings (JSON under the keys `scenes`, `displays` and `adaptive`).

**`DeviceControl<Value>`** is where the slider rules live:

- `value` is what the UI shows. A user change sets it at once (optimistic). `deviceValue` is the last value actually read.
- At most one write is in flight. Changes arriving meanwhile replace a single pending value. A drag therefore sends the first value, then the newest one each time the bus is free, and the queue can never grow. A value equal, after quantization, to the last one written is not sent.
- When writes stop, and the user is not dragging, the control reads the value back after `settleDelay` (800 ms; 2 s for the input selector, which `Monitor` builds with a longer delay because a switch takes a moment), so the slider ends up where the monitor actually is.
- A generation counter is taken when a read is issued. The result is applied only if no change, pending write or drag happened since, so a slow reply cannot overwrite newer intent. The same rule applies to a failed read.
- A failed write shows a warning on that control only, and the warning stays after the read-back has put the slider back to the device's value, so a rejected change never vanishes silently. Write failures never change the monitor's status: only reads decide that, so one dropped write cannot swap the controls out from under a drag.
- No write is sent before the first successful read: until then the device's range, and whether it answers at all, are unknown.
- `endInteraction()` ends a drag the UI can no longer finish. SwiftUI never reports the end of a drag on a slider it removed, so the menu calls it on every control whenever it opens or closes, the window when it closes or is minimised, and each slider when SwiftUI removes it.

**`InputSelector`** only *stages* a choice (`request`). The write happens on `confirm()`, which the menu and the window call from an explicit button that is deliberately not the default action. Its underlying control is internal to `GlimCore`, so nothing else can write an input. A staged choice is dropped when the menu closes, and when the window closes or is minimised.

**`ColorPresetSelector`** writes a pick at once: a preset is harmless and undone with one more pick, and the factory preset is always among the options. Its control's value is a `ColorPresetValue`, an offered preset by the value that selects it, or whatever else was read. That keeps the shown value in one domain even though the HP reads 0x14 back in its own numbering. The color temperature and the preset move together on the monitor, so `Monitor` wires each control's `onSettled` (called once a control has read back after its own writes) to re-read the other.

**`Monitor`** picks a profile from the EDID identity. The HP E27m G4 has a tested profile, with input switching and the color controls marked untested; anything else is built from its capabilities string, and a control is kept only if it answers a read. Its `status` (connecting, ready, not responding) comes from the outcome of DDC reads. Audio failures do not count, because they concern another device, and the USB speakers stay usable while DDC is silent. On a reconnect its DDC controls are removed at once and rebuilt on the new channel, and every control it replaces is invalidated, so none stays on screen dead or keeps writing in the background.

**`MonitorManager`** rescans when IOKit, AppKit or a wake says displays changed, debounced by 750 ms, and one scan at a time. It keys monitors by identity, so a monitor that comes back with a new transport keeps its object and gets a new channel. It keeps **one channel per transport**: when a monitor object is replaced on the same bus (for instance once its EDID is published and its key changes), the old and the new one share that channel, so their traffic is still serialised. Monitors that are gone are invalidated: every task is cancelled, and an operation still queued on the channel sends nothing (see *Concurrency*).

**`DisplayScene`** (`GlimCore/Scenes`) is a named set of brightness, contrast and color per monitor, keyed by `Monitor.id`, with the parts it applies. It is captured from controls that have been read, so a color that can't be put back (custom RGB, an unknown preset) is left out. Applying goes through the same `DeviceControl.set` and `ColorPresetSelector.select` as the UI, so a control not yet read gets nothing. Input and volume are never part of a scene. A scene is active while every connected monitor it holds shows its parts.

**`AdaptiveController`** (`GlimCore/Adaptive`) drives automatic brightness and evening warmth. `AdaptiveEnvironment` is what it reads: the light sensor (private HID event system, event type 12), the built-in display's brightness (private `DisplayServicesGetBrightness`), the lid (`AppleClamshellState`) and the clock. Both private readers are resolved with `dlsym`; a missing one makes that source fall back to the schedule. One reading per tick serves every display, and the sensor is read only while a display uses it. Readings are averaged in log space, a change must exceed 10% and last two ticks, and the level fades in steps through `DeviceControl.set(_:automatic: true)`. A user change counts in `DeviceControl.userChanges`, which is how the controller tells that someone took over: it pauses that display and, if learning is on, bends its `BrightnessCurve` (monotonic, over log10(lux + 1)) through the choice. Nothing runs while no display uses it, or while the displays sleep.

**`GlimStore`** (app) keeps the scenes and each display's own name and menu choices as JSON in `UserDefaults`, and sets unreadable data aside under `<key>.unreadable` instead of overwriting it. Views get it from the environment (`\.glimStore`). Without one, as in most tests, they offer no scenes and use Glim's names.

## Menu, window and Dock

The menu and the main window are two views of the same `MonitorManager` and the same `Monitor` objects. Neither keeps a copy of any value, so a change made in one shows in the other at once, and each monitor still has exactly one channel.

`MainWindowController` owns the window in AppKit rather than as a SwiftUI `Window` scene. The app delegate opens it on reopen and at launch (unless macOS started Glim at login), which a scene doesn't allow, and before macOS 15 a scene's launch and restoration can't be turned off. `AppPresence` keeps `LSUIElement`'s menu-bar-only policy except while the window is open, when the settings ask for the Dock, or when the menu bar icon is hidden.

## Concurrency

- **Each monitor's `DDCChannel` is an actor whose executor is its own `DispatchSerialQueue`.** The IOAVService calls are synchronous, and the protocol needs pauses between them, so a transaction (request, pause, reply) runs start to finish with blocking sleeps and **no suspension point**. Actors are reentrant, but nothing can run inside a transaction because it never awaits; and the blocking happens on the channel's own thread, never on the main thread or the Swift concurrency pool.
- Reading the capabilities string takes about 3 s, and `Monitor` gives up on it after a 20 s deadline. It is one transaction per fragment, so a slider write can run between fragments.
- **`CoreAudioOutput`** is an actor on its own queue too: CoreAudio property calls are IPC to the audio server.
- **State is on the main actor.** Its methods await the hardware actors, so the main thread is free while the bus is busy.
- **No polling by default.** Glim reads when a monitor connects, each time the menu opens or the window becomes key (at most once every 2 s per monitor), and after writes settle. With automatic brightness and evening warmth both off, idle CPU is zero. With either on, `AdaptiveController` takes a reading every 2 s (not while the displays sleep, and not while no display uses it).
- **Timeouts and cancellation.** A DDC transaction cannot be interrupted, so `withDeadline` races it against a timer with a first-wins continuation and cancels whichever side loses. The caller gets `.timedOut` after 5 s. Cancelling the caller cancels the operation and returns at once. Every `DDCChannel` operation checks for cancellation before it touches the bus, so an operation whose caller timed out or went away, still queued behind a stuck one, sends nothing when its turn comes: a write the UI reported as failed can never land later. An overrunning transaction itself keeps its queue until it finishes.
- **Task ownership.** Each control owns at most one writer task and one reconcile task. Each monitor owns its configuration task, and the manager owns its pending rescan. All of them capture `self` weakly and are cancelled on `invalidate()` or `stop()`.

### Escape hatches, and why each is sound

There is no `@unchecked Sendable` and no `nonisolated(unsafe)` under `Sources/` (checked with grep). Unsafe or unchecked constructs:

| Where | What | Why it is sound |
| --- | --- | --- |
| `IOAVService.swift` | `dlsym` plus `unsafeBitCast` to `@convention(c)` types | The function types mirror the C prototypes used by m1ddc and `tools/glim-cli`. Resolving at run time is what allows a graceful failure. |
| `IOAVService.swift` | `Unmanaged` for the IOAVService CF object | `Create` returns +1, taken once with `takeRetainedValue`. Calls pass it unretained while `self` holds it. |
| `DisplayServiceNotifier.swift` | `self` as the IOKit refCon, `MainActor.assumeIsolated` in the callback | The notification port's queue is `.main`, so the callback is on the main thread. The refCon holds a +1 reference, released by `stop()` only after the port is destroyed, so a notifier nobody stopped leaks instead of dangling. |
| `LightSources.swift` | `dlopen` and `dlsym` of the private HID event-system functions (light sensor) and `DisplayServicesGetBrightness`, `unsafeBitCast` to `@convention(c)` types, `Unmanaged<CFTypeRef>` results taken with `takeRetainedValue` | Every symbol is looked up once and the reader is not created if any is missing, so a macOS without them loses that source and Glim still launches. The function types mirror the C signatures; the `Copy`/`Create` functions return +1 objects, taken once. Both readers are only called on the main actor and only read. |
| `AudioOutput.swift` | `Unmanaged<CFString>?` as the out-parameter of `AudioObjectGetPropertyData` | CoreAudio hands back a +1 string, so `takeRetainedValue` is called once, and only when the call succeeded. |
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
| `DDCError` | channel and transport | `noReply`, `writeFailed` / `readFailed` (IOReturn), `serviceUnavailable` (the display's IOAVService could not be opened, probably because it was disconnected) and `timedOut` are transient. `unsupported(code)`, `refused(code)` (a code outside `DDCChannel.writableCodes`) and `transportUnavailable` are final. |
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
| `IdentityAndProfileTests` | nothing | EDID identity keys, manufacturer codes, and what the HP profile says was tested |
| `DiscoveryTests` | nothing | joining transports to framebuffers, including pairing by elimination |
| `ColorTests`, `SettleNotificationTests` | nothing | color temperature in kelvin, the HP's preset numbering against the measured fixture, custom colors, and a control reporting once that it has settled |
| `SceneTests` | nothing | capturing and applying scenes, parts left out, absent and unread displays |
| `BrightnessCurveTests`, `DayScheduleTests` | nothing | the learned lux-to-brightness curve, and the day and night schedule with its ramps |
| `AdaptiveControllerTests` | nothing | automatic brightness and warmth with a scripted environment: smoothing, hysteresis, pausing on a change by hand, the lid |
| `GlimStoreTests` | nothing | scenes, display choices and adaptive settings surviving a relaunch, and unreadable data set aside |
| `RenderTests` | a GUI session | the menu, the whole window (frame and toolbar included) and the settings, in every state, light and dark, offscreen |
| `MainWindowTests`, `AppPresenceTests` | a GUI session | one window, launch and reopen, the Dock rule, interactions ended on close, and the window and the menu following each other through their real sliders |
| `HardwareTests` | an HP E27m G4, `GLIM_HARDWARE_TESTS=1` | the real thing; every write is reversible and restored |
| `SensorHardwareTests` | a MacBook with the lid open, `GLIM_HARDWARE_TESTS=1` | reads the light sensor and the built-in brightness; writes nothing |

See [development.md](development.md) for how to run each.
