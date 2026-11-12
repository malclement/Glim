# How Glim talks to the monitor

Glim reaches the monitor over two independent channels:

| Channel | Carries | macOS API |
| --- | --- | --- |
| **DDC/CI** over the display link | brightness, contrast, color, input | private `IOAVService` I2C functions |
| **USB Audio** on the monitor's USB hub | speaker volume and mute | CoreAudio |

Everything here was observed on an HP E27m G4 (firmware 1.0) connected over USB-C to an M4 MacBook Air running macOS 26.5. ✅ marks behaviour verified on that hardware; ⚠️ marks behaviour that is implemented but not verified.

## Where this comes from

The protocol was reverse-engineered before the app was written. That work is the source of truth, and Glim follows it:

| Source | Contents |
| --- | --- |
| [controls.md](controls.md) | Every DDC/CI control on the HP E27m G4: values, behaviour, hazards, and what was verified. |
| [ddc-ci-protocol.md](ddc-ci-protocol.md) | Wire format, timing and quirks, as observed. |
| [macos-usb-webcam.md](macos-usb-webcam.md) | The monitor's USB Audio device, and the other non-DDC surfaces. |
| [`tools/glim-cli`](../tools/glim-cli) | The C CLI used for the research. It is the reference implementation of the wire protocol. |
| [`hp-e27m-g4-frames.txt`](../Tests/GlimCoreTests/Fixtures/hp-e27m-g4-frames.txt) | Frames captured from the monitor, shifted reads included. They are test fixtures. |
| [`HardwareTests.swift`](../Tests/GlimCoreTests/HardwareTests.swift) | Re-verifies discovery, reads, writes and audio on the real monitor (`make hardware-test`). |

## DDC/CI transport

```
Glim ─IOAVServiceWriteI2C / ReadI2C─▶ DCP display coprocessor ─DP AUX─▶ monitor scaler, I2C 0x37
```

- ✅ Apple silicon has no `/dev/i2c`. The only path to the monitor's DDC bus is `IOAVServiceCreateWithService`, `IOAVServiceWriteI2C` and `IOAVServiceReadI2C` on the `DCPAVServiceProxy` whose `Location` is `External`. m1ddc, MonitorControl and BetterDisplay use the same functions.
- These functions are private. Glim resolves them with `dlsym` when it starts. If a macOS release removes them, the menu says DDC/CI is unavailable instead of the app failing to launch.
- ✅ Writes go to chip address `0x37` with data address `0x51`, and reads come from the same pair.

### Framing

```
host → display   [0x80 | n] [payload…] [checksum]          checksum = 0x6E ^ 0x51 ^ every byte before it
display → host   [0x6E] [0x80 | n] [payload…] [checksum]   checksum = 0x50 ^ every byte before it
```

✅ Glim's encoder reproduces every captured request byte for byte (`DDCMessageTests`). Every read is 40 bytes, and the length byte says how much of it is the reply.

### Requests Glim sends

| Request | Payload | Sent | Status |
| --- | --- | --- | --- |
| Get VCP | `01 <code>` | when a monitor connects, each time the menu opens or the window comes forward, and once writes settle | ✅ |
| Set VCP 0x10 brightness, 0x12 contrast | `03 <code> <hi> <lo>` | while a slider moves | ✅ round trip in the hardware tests |
| Set VCP 0x0C color temperature | `03 0C 00 <steps>` | while the slider moves; 1 to 126 on the HP. While 0x0C reads 0 (sRGB, native, custom RGB), the first one is preceded by 0x14 ← 05, so the temperature lands in a preset that has one | ✅ written and read back with the CLI; ⚠️ the app's path, and a lone 0x0C write from sRGB, not yet run on the hardware |
| Set VCP 0x14 color preset | `03 14 00 <value>` | when a preset is picked. The HP reads it back in its own numbering, so the active preset is recognized from 0x14 *and* 0x0C ([controls.md](controls.md#0x14-color-preset-mapping)), and each code is read again after the other settles, since they move together | ✅ same |
| Set VCP 0x60 input | `03 60 00 <value>` | only after the user confirms the switch, in the menu or the window | ⚠️ never sent to the hardware: the owner deferred input switching ([open-items.md](open-items.md)) |
| Capabilities | `F3 <offset hi> <offset lo>` | only for monitors Glim has no profile for | ✅ string reassembled from the capture and re-read by the hardware tests |

For a monitor without a profile, Glim can also read and write 0x62 (volume) and 0x8D (mute) when its capabilities list them, and 0x0C and 0x14 when they are listed and answer, with 0x0B giving the kelvin per step. That path has never run against such a monitor.

**What Glim never sends**, by construction: there is no code path to these.

| Code | Why |
| --- | --- |
| `04` restore factory defaults | wipes settings that DDC cannot read back |
| `D6` power | 04/05 turn the monitor off, and DDC may not reach it again |
| `CA` OSD lock | locks the monitor's buttons |
| `0C` (DDC command) save settings | unverified, and unneeded: settings persist without it |
| `DC`, `E0`–`FF` vendor codes | HP's sub-code protocol starts every read with a write. `E1` sub-code 04 value 00 turns DDC/CI off, and sub-code 27 value 0A is a master reset. |

Writes reach `DDCChannel.write` from these places only: the brightness, contrast and color temperature sliders, the color preset picker, the input picker after its confirmation, and DDC volume and mute on profile-less monitors that list 0x62 and 0x8D. Below all of them, `DDCChannel` refuses any code outside `writableCodes` (0x0C, 0x10, 0x12, 0x14, 0x60, 0x62, 0x8D), whoever asks.

### Timing and retries

| Rule | Value | Source |
| --- | --- | --- |
| Write every frame twice | 2 writes, 10 ms before each | ✅ the DCP occasionally drops a write; m1ddc does the same |
| Wait before reading a reply | 50 ms | ✅ MCCS asks for at least 40 ms |
| Quiet time after a Set | 50 ms | MCCS |
| Get soon after a Set | no Get within 200 ms of any Set; a code that reads 0 within 2 s of being set non-zero is read again, up to twice, 150 ms apart | ✅ the HP reads 0 right after a set of the same code; ⚠️ applied to every code because nobody checked the others |
| Attempts per Get | 4 | ✅ shifted reads are common (below) |
| Attempts per capabilities fragment | 6 | ✅ |
| Reopen the IOAVService | after 3 consecutive transport failures, or 2 Gets in a row with no valid reply | ⚠️ for a service gone stale across sleep; not observed |
| Read-back after writes stop | 800 ms for sliders and pickers; 2 s for the input selector, because a switch takes a moment and the monitor may go quiet | defensive; input switching is untested on hardware |
| Timeout per control operation | 5 s; an operation whose caller timed out or was cancelled is dropped before it reaches the bus | defensive; no hang observed |
| Deadline for the whole capabilities read | 20 s (`Monitor`); the string normally takes about 3 s | defensive |
| Capabilities read that fails partway | what arrived is kept and parsed, as `glim caps` does | ✅ the parser copes with a truncated string |

Each transaction (request, pause, reply) runs to completion on the monitor's own serial queue, so two transactions never interleave on the bus.

### Validating replies: shifted reads are normal

✅ The DCP regularly returns a **shifted** read: the buffer starts with the tail of the request just written, or partway into the reply, with no `0x6E` in front. In the capture, 7 of 53 reads were shifted, mostly while reading the capabilities string. Glim rejects a read unless:

1. it starts with `0x6E`,
2. its length byte has the `0x80` bit set, except the timing reply, whose length byte is a bare `0x06`,
3. the buffer holds the whole message, and
4. the checksum matches.

A Get reply must also name the code that was requested, and a capabilities fragment must carry the requested offset, so a stale reply for another request is never mistaken for this one. Rejected reads are retried. ✅ Every shifted read in the capture is rejected and every well-formed one accepted (`DDCMessageTests`).

A reply with result code `01` means the monitor does not support the code. That is final, not retried, and the control is not shown.

### Which monitor is which

✅ Each external display pipe `dispextN` has a framebuffer (`IOMobileFramebufferShim`, a child of the `dispextN` device). The framebuffer's `DisplayAttributes.ProductAttributes` hold the decoded EDID: manufacturer, product, serial and name. The `DCPAVServiceProxy` sits under the coprocessor (`dcpextN`), not under the framebuffer, but its parent is named `dispextN:dcpav-service-epic:0`. Glim joins the two on that `dispextN` prefix, never on enumeration order. Only external framebuffers count: the `external` property or a `dispext` pipe name, so the built-in panel (`disp0`) can never be matched. A proxy whose framebuffer has not published its EDID yet waits for the next rescan. Only if a proxy's name matches no framebuffer at all, because the naming changed, are a single such proxy and a single unclaimed framebuffer paired by elimination.

A monitor's identity is `manufacturer-product-serial`, for example `HPN-3753-<serial>`. When the EDID has no usable serial, identical monitors also get their display pipe in the key, and the menu numbers them.

Glim rescans when IOKit publishes or terminates a `DCPAVServiceProxy`, when AppKit reports new screen parameters, and after the system or the displays wake. A monitor that comes back with a new proxy keeps its place in the menu and gets a fresh channel.

## Volume and mute: USB Audio, not DDC

✅ The HP's speakers are the USB Audio device "HP E27m G4 USB Audio" (vendor 0x03F0, product 0x0B86) on the monitor's USB hub, so Glim needs the USB-C cable's USB connection for them.

- **Volume** uses the HAL's virtual main volume (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume` through the AudioObject API), the property the macOS volume menu uses. The device has per-channel volume but no main element; this property drives both channels and keeps their balance. ✅ Set, read back and restored to the exact dB in the hardware tests.
- **Mute** is the device's main mute. ✅ Toggled, read back and restored in the hardware tests.
- ✅ DDC **0x62 is only a mirror** of the USB level: writes over DDC are accepted and ignored, and the value follows the USB volume.
- ✅ **DDC 0x8D does not mirror the USB mute** (found 2026-11-04): with the USB output muted, 0x8D still reads 2 (unmuted). The two mutes are independent; Glim drives the USB one, which is the one macOS shows.
- Glim finds the device by name (`HP E27m G4…`, USB transport, with output streams). With two monitors of the same model connected, or any display whose EDID is not known yet (it could be a second one), nothing says which USB device belongs to which display, so none gets a volume control: a wrong guess would change some other speaker. ⚠️ One case it cannot see: an HP connected for video only, next to a second HP connected by USB only, would get the second one's speakers.
- The speakers are read whenever the menu opens or the window comes forward, even while DDC is silent, and stay usable then.

## Limitations and unknowns

- ⚠️ **Input switching is untested on hardware.** Whether DDC keeps answering after the monitor switches away from USB-C is unknown; Glim expects that it may not, and shows "Not responding". Switching to a port with nothing connected blanks the screen until someone presses the monitor's input button.
- Glim cannot tell when settings change from the monitor's own buttons. MCCS 0x02/0x52 might report that, but they are untested. Glim re-reads every control each time the menu opens or the window comes forward, instead of polling.
- Other DDC tools (MonitorControl, BetterDisplay, m1ddc, `glim`) running at the same time can interleave with Glim on the bus. Run one at a time.
- A monitor that is asleep, or has DDC/CI turned off in its menu (HP: Management › DDC/CI), does not answer; the menu says so.
- Only the HP E27m G4 has been tested. Other monitors get brightness and contrast if they answer, and the inputs and DDC volume their capabilities string lists, all marked untested.

## Adding a monitor safely

1. Read its capabilities with `glim caps` and do a full read-only scan with `glim scan --all` ([`tools/glim-cli`](../tools/glim-cli)). Reads are harmless.
2. Write only standard, reversible codes (0x10, 0x12), read each one back, and restore it. Snapshot every readable code before and after each write to catch coupled side effects: on the HP, any RGB-gain write switches the color preset.
3. Never send a code nobody has documented for that model, and never write 0x04, 0xD6, 0xCA or a vendor code (0xE0–0xFF) as an experiment.
4. Add a `MonitorProfile` with only the controls you verified, plus a matching rule on EDID manufacturer and product, and record what you verified in the pull request.
