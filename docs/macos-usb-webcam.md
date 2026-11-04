# Everything except DDC: macOS, USB, audio and webcam

DDC/CI ([controls.md](controls.md)) is one control surface of several. This document covers the rest: what macOS can read from or change on the HP E27m G4 through CoreGraphics, CoreAudio, IOKit/USB and HID.

All probing was read-only, except the one volume test marked below. Run on 2026-11-04 on an M4 MacBook Air, macOS 26.5. The probes live in [`tools/macos-probe/`](../tools/macos-probe); `make` there builds them.

✅ = observed. ⚠️ = inferred or documented but untested.

## Control matrix

| Feature | Read | Control | How |
| --- | --- | --- | --- |
| Hardware brightness, contrast, color, sharpness, menu | ✅ | ✅ | DDC: `glim`. See [controls.md](controls.md). |
| Resolution, refresh, HiDPI | ✅ | ✅ public API | `CGConfigureDisplayWithDisplayMode`; `displayplacer`; BetterDisplay |
| Arrangement, main display, mirroring | ✅ | ✅ public API | `CGConfigureDisplayOrigin` / `CGConfigureDisplayMirrorOfDisplay`; `displayplacer` |
| Rotation | ✅ | ⚠️ private API or System Settings | `displayplacer degree:` |
| Gamma (software dim or tint) | ✅ | ✅ | `CGSetDisplayTransferByTable`. Not persistent: it is lost when the process that set it exits. |
| ColorSync profile | ✅ | ✅ | `ColorSyncDeviceSetCustomProfiles`; System Settings |
| macOS software brightness | ✅ unsupported | — | DisplayServices returns error 1000 for this display |
| HDR | ✅ not supported | — | SDR panel, 8 bpc |
| Night Shift | ✅ | ✅ system-wide | private `CBBlueLightClient` |
| True Tone | — | — | ⚠️ applies to the built-in panel and Apple displays only |
| EDID | ✅ | read-only | IORegistry; `edidprobe` |
| DP lanes vs USB 3 | ✅ | — | macOS has no control over this. Any option would be on the monitor's side ⚠️ |
| USB-C charging power | ✅ 65 W | — | `pmset -g adapter`, `ioreg` |
| **Speaker volume** (per channel) and mute | ✅ | ✅ | CoreAudio on the "HP E27m G4 USB Audio" output. `tools/macos-probe/hpvolume`. **DDC 0x62 mirrors this level.** |
| Mic gain (per channel) and mute | ✅ | ✅ | CoreAudio |
| Sample rate | ✅ | ✅ | `kAudioDevicePropertyNominalSampleRate` |
| Mic-to-speaker sidetone | ✅ present in the USB descriptor | ⚠️ raw UAC requests only | not exposed by CoreAudio |
| Front-panel audio keys | ✅ in the HID descriptor | listen only | IOHIDManager (needs Input Monitoring permission) |
| Telephony LEDs (mute, ring, hold…) | ✅ in the HID descriptor | ⚠️ host-drivable | HID output report 9 |
| HP vendor HID channel | ✅ exists | **don't use** | ⚠️ undocumented; likely HP Display Center / firmware |
| Webcam (5 MP + IR) | not enumerated | AVFoundation + UVC | `camprobe`, `usbdescprobe`, `uvc-util` |

## macOS display layer

### Identity and arrangement

- ✅ **CoreGraphics IDs:** CGDirectDisplayID 3; the built-in panel is 1 and is the main display.
- ✅ **EDID IDs:** vendor `HPN` (0x220E), product 0x3753. The binary serial is a placeholder (0x01010101); the unit's real serial is in the EDID serial-number string, and the display has its own UUID; neither is recorded here.
- ✅ **Position:** origin (-404, -1440), so the HP sits above the MacBook, roughly centred. Mirroring is off, rotation 0°. `system_profiler` reports "Rotation: Supported", and the stand pivots ±90°.

### Display modes

✅ `displayprobe` lists 79 modes when duplicate low-res modes are included.

- **Current:** mode id 40, 2560×1440 @ 75 Hz, flagged native and default. Native at 60 Hz is id 41.
- **HiDPI:** the only HiDPI mode at native pixels is 1280×720 pt @2x, at 75 or 60 Hz. ⚠️ BetterDisplay can create a 1920×1080 HiDPI mode, but this wasn't tested.
- **Refresh rates:** 50, 60 and 75 Hz only. No VRR.
- **Scaled modes:** from 2048×1152 down to 800×600. This matters for DDC 0x86 (scaling), which only does something at non-native resolutions.

### Brightness, gamma and color

- ✅ **macOS can't dim the panel.** `DisplayServicesCanChangeBrightness` returns false and `DisplayServicesGetBrightness` returns error 1000. Real backlight dimming has to go through DDC 0x10.
- ✅ **The gamma table is an identity ramp:** 1024 entries, gamma 1.0. Nothing such as f.lux or Lunar is altering it now.
  - Software dimming through the gamma table costs contrast and bit depth.
  - It is undone when the process that set it exits.
- ✅ **ColorSync profile:** "HP E27m G4", generated from the EDID, at `/Library/ColorSync/Profiles/Displays/HP E27m G4-<uuid>.icc`.
- ✅ **HDR:** none. EDR headroom is 1.0, and the EDID has no HDR metadata block.
- ✅ **Pixel encodings:** RGB 4:4:4, YCbCr 4:4:4 and YCbCr 4:2:2, all 8 bpc. Max pixel rate is 296 MHz.
- ✅ **Night Shift:** available system-wide, no schedule set, CCT 5110 K.
  - ⚠️ Applies to external displays through the display pipeline.
  - ⚠️ The status fields come from reverse-engineering the private API.

### EDID

✅ `edidprobe`: 256 bytes, both checksums OK.

**Base block (EDID 1.4)**

- **Made and wired:** manufactured 2023 week 34. DisplayPort input, 8 bits per color.
- **Size and color:** 60 × 34 cm, gamma 2.2. White point is about D65.
- **Power states:** active-off only.
- **Timings:**
  - preferred: 2560×1440 @ 59.95 Hz (241.5 MHz)
  - range limits: V 50–75 Hz, H 30–115 kHz, max pixel clock 340 MHz

**CTA-861 extension**

- 2560×1440 @ 74.97 Hz (296 MHz) and the standard TV timings.
- **`basicAudio = no`, and there is no audio data block.** DisplayPort audio is therefore unavailable, and the speakers are reachable only through USB Audio.

### USB-C link and power

- ✅ **DisplayPort:** 4 of 4 lanes at HBR2 (5.4 Gbps). The DP sink is "Dp1.2" with OUI 00-E0-4C, i.e. a Realtek scaler.
- ✅ **USB runs at 2.0 only.** Active transports are `CC, USB2, DisplayPort`. The monitor advertises USB 3.2 Gen1 in its PD identity, but all four high-speed lanes are carrying DisplayPort.
  - So everything on the monitor's hub shares 480 Mb/s: the 4 USB-A ports, the Ethernet adapter and the webcam.
  - ⚠️ 2560×1440 @ 75 Hz needs about 7.1 Gbps, which would fit in 2 lanes. USB 3 would need a monitor-side option to prefer USB data. None was found in the spec sheet; this is an open item.
- ✅ **Power delivery:**
  - Source offers: 5 V/3 A, 9 V/3 A, 12 V/5 A, 15 V/4.33 A, 20 V/3.25 A.
  - Contract: **20 V / 3.25 A = 65 W**, and the Mac is charging.
- ✅ **Cable:** HP passive USB-C, 20 V / 5 A, USB 3.2 Gen1, about 2 m. This matches the bundled 1.8 m cable.

## USB devices on the monitor's hub

✅ From `system_profiler SPUSBHostDataType`, `ioreg` and `usbdescprobe`. Everything sits behind one upstream hub:

```
GenesysLogic USB2.1 Hub 03f0:0a86 (upstream, self-powered)
├─ internal hub 03f0:0e86 — 4 ports, all empty now (⚠️ USB-A ports / webcam slot)
├─ Realtek RTL8153 0bda:8153 "USB 10/100/1000 LAN" (RJ-45, CDC-ECM)
└─ HP E27m G4 USB Audio 03f0:0b86 (full speed, UAC 1.0)
    ├─ if 0–2  audio control + 2 streaming interfaces
    └─ if 3    HID (183-byte report descriptor, interrupt IN 0x82)
```

There is no Billboard device and no vendor-class (0xFF) interface.

### USB Audio

| | Output | Input |
| --- | --- | --- |
| Channels | 2 | 2 |
| Rates | 8 / 16 / 32 / 44.1 / 48 kHz (now 48) | 8 / 11.025 / 16 / 32 / 44.1 / 48 kHz (now 48) |
| Formats | 16- or 24-bit PCM | 16-bit PCM |
| Volume | per channel (elements 1 and 2), -74…0 dB, **now -18.03 dB** | per channel, now -1.00 dB |
| Mute | master (element 0) | master (element 0) |

- **Topology** (from the descriptor):
  - Playback: stream → mixer 10 → feature unit 2 (mute, per-channel volume) → speaker.
  - Capture: 2-channel mic → feature unit 6 → selector → stream.
  - A second, 1-channel mic path goes through feature unit 9 into mixer 10. ⚠️ That is a **sidetone** (mic to speaker), which CoreAudio doesn't expose.
- **No device-level volume.** There is no element-0 volume, only channels 1 and 2. CLIs that set element 0 do nothing.
- **Not the default output.** `osascript set volume` acts on the default output only, and the default output is the MacBook speakers. To change the HP's level, either make it the default (`SwitchAudioSource`) or set elements 1 and 2 directly, as `tools/macos-probe/hpvolume` does.

✅ **DDC 0x62 mirrors this volume.** This is the one write made outside DDC: the level was changed and then restored exactly.

| USB volume (scalar) | DDC 0x62 reads |
| --- | --- |
| 0.0000 | 0 |
| 0.2500 | 9 |
| 0.5524 | 29 |
| 0.5721 (-18.03 dB, original) | 30 |
| 0.5727 | 31 |
| 0.8948 | 77 |

- The mapping is non-linear and follows the dB curve.
- Writing 0x62 over DDC is accepted on the wire but ignored.
- **To change the speaker level, use CoreAudio.** Read it from either side.
- The scalar has coarse steps. Use `hpvolume db <dB>` to reach every hardware step.

### HID: the monitor's front-panel keys

✅ From `hidprobe`, which decodes the report descriptor without opening the device.

| Collection | Reports |
| --- | --- |
| Consumer Control | in #2: **Volume Up, Volume Down, Mute** (the speaker keys); in/out #1: 61-byte opaque tunnel |
| Telephony Headset | in #8: **Phone Mute** (mic-mute key), Hook Switch, Flash, Redial, Programmable Button 1; out #9: LEDs (Mute, Off-Hook, Ring, Speaker, On-Line, Hold) |
| Vendor page 0xFF0B | feature #42 (61 B), out #42 (60 B), out #45 (16 B), in #44 and #45 (16 B) |

- ⚠️ **The volume and mute keys behave as media keys.** macOS applies them to the default output. Today that's the MacBook speakers, not the monitor's.
- ⚠️ **macOS ignores the mic-mute key.** Teams or Zoom may consume it and drive the mute LED.
- ⚠️ **The vendor reports are HP's private channel.** Likely uses are HP Display Center, firmware updates or DSP. **Do not write to them.**

## Webcam

✅ **Not enumerated now.** Only the MacBook and iPhone cameras appear, and no new HP product ID is on the hub. ⚠️ The pop-up camera is probably disconnected from USB when retracted, which makes retracting it a hardware privacy switch.

**What HP documents** (QuickSpecs c07718766):

- 5 MP sensor
- independent tilt, -20° to +5°
- pop-up privacy
- RGB and IR lenses, plus an IR LED (Windows Hello)
- activity light
- Zoom certified

⚠️ The IR side has no use on macOS.

**To check once it is popped up** (all read-only):

1. `system_profiler SPCameraDataType SPUSBHostDataType` shows the new product ID and where it sits on the internal hub.
2. `tools/macos-probe/usbdescprobe` decodes the UVC camera-terminal and processing-unit control bitmaps (the exact controls supported), extension-unit GUIDs, and formats and frame rates. It also shows whether there is an IR function.
3. `tools/macos-probe/camprobe` shows the AVFoundation formats and frame rates, and Center Stage / Portrait support.
   - macOS AVFoundation has no zoom, field-of-view or HDR API; those are iOS-only.
4. UVC class requests (GET_CUR / MIN / MAX / RES / INFO) read the current values and ranges of those controls. Tools for this: `uvc-util`, the CameraController app, or libuvc.
   - ⚠️ SET_CUR is the control path.
   - ⚠️ Writing an extension unit can change persistent camera state.

⚠️ The webcam shares the hub's USB 2.0 link, so above about 720p30 it needs MJPEG or H.264.

## Physical controls and OSD

From HP QuickSpecs; ⚠️ not cross-checked against the unit.

- **Front:** mic mute, speaker mute, volume up/down; 5 OSD buttons (Menu, Minus/Brightness, Plus/Color, OK/Next Input, Power); power LED; 3.5 mm combo jack.
- **Function buttons:** 3 user-assignable, 7 options each.
- **OSD top menus:** Brightness+, Color, Image, Input, Power, Menu, Management, Information, Exit. 11 languages, which matches the 11 values DDC 0xCC accepts.
- **Picture:** 10 user-programmable modes and 16 user presets, RGB gains, default 6500 K. HP Eye Ease low blue light (hardware), flicker-free.
- **Ports:** HDMI 1.4; DP 1.2 in and DP 1.2 out (daisy chain); USB-C (DP alt mode, 65 W PD); RJ-45 (MAPT, Wake-on-LAN, PXE); 4 × USB-A.
- **Software:** HP Display Center (Windows only) and HP Display Manager. There is no macOS software. Firmware is user-updatable from Windows.

## Tools that exist but aren't installed

✅ Checked with `brew info`. Versions as of 2026-11-04.

| Package | What for |
| --- | --- |
| `displayplacer` (formula 1.4.0) | resolution, refresh, origin, mirroring, rotation |
| `switchaudio-osx` (formula 1.2.2) | `SwitchAudioSource`: make the HP the default output or input |
| `betterdisplay` / `lunar` / `monitorcontrol` (casks) | GUI DDC, HiDPI and gamma control |
| `cameracontroller` (cask), `libuvc`, `uvc-util` | UVC webcam controls |
| `hidapi` (formula 0.15.0) | HID reports |
| `brightness` (formula 1.2) | ⚠️ DisplayServices-based, so it can't dim the HP |

## Sources

- HP QuickSpecs, *HP E27m G4 QHD USB-C Conferencing Monitor*, c07718766 v2, 2021-11-15 (model 40Z29AA). [Bechtle mirror](https://media.bechtle.com/asrc/180712/1c4b3d4ee288fc9434f5175bf56070570/c3/-/90001173302546e497e2dba4e8b2c98c/hp-e27m-g4-qhd-konferenzmonitor-datenblatt-2)
- [HP E27m G4 Maintenance & Service Guide (ManualsLib)](https://www.manualslib.com/manual/2531816/Hp-E27m-G4.html)
- [HP user guide](https://support.hp.com/us-en/product/setup-user-guides/hp-e27m-g4-qhd-usb-c-conferencing-monitor/2100888402) (not fetched; the page needs JavaScript)
- Tools: [displayplacer](https://github.com/jakehilborn/displayplacer), [switchaudio-osx](https://github.com/deweller/switchaudio-osx/), [BetterDisplay](https://betterdisplay.pro/), [Lunar](https://lunar.fyi/), [MonitorControl](https://github.com/MonitorControl/MonitorControl), [CameraController](https://github.com/Itaybre/CameraController/), [libuvc](https://libuvc.github.io/)
