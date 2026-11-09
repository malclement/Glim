# 5. Beyond DDC/CI

A monitor is often several devices: a display on the video link, plus a USB hub carrying speakers, a microphone, buttons, a webcam or Ethernet. Each needs its own probe, and some controls you'd expect over DDC/CI actually live here. On the HP, the speakers' volume is a USB Audio setting that DDC 0x62 only mirrors. All of the probes below are read-only.

You need the monitor's USB vendor ID from [phase 1](01-prepare.md#identify-the-monitor), for example `0x03f0` for HP.

## Display layer and EDID

```sh
tools/macos-probe/displayprobe --external        # modes, HiDPI, gamma, colour profile, HDR, software brightness
tools/macos-probe/edidprobe                      # EDID: timings, range limits, audio support, colorimetry
ioreg -r -c AppleHPMInterfaceType10 | grep -i TransportsActive   # USB-C: which transports share the cable
pmset -g adapter                                 # power delivered over USB-C, if any
```

Things to note:
- **Whether macOS can dim the display itself.** `canChangeBrightness`: if it says no, brightness exists only over DDC/CI.
- **Whether the EDID declares audio** (`basicAudio`, an audio data block). If it doesn't, speakers can only be USB.
- **On USB-C, `TransportsActive`.** `("CC","USB2","DisplayPort")` with four DisplayPort lanes means the monitor's USB hub is running at USB 2.0.

## USB audio

```sh
system_profiler SPAudioDataType | grep -i -A6 '<model or brand>'
tools/macos-probe/audioprobe '<model or brand>'
```

`audioprobe` lists each volume and mute control per scope and channel, and whether software may set it. Look for:
- **No main (element 0) volume**, only per-channel volume. Tools that set element 0 then do nothing. Glim uses the HAL's virtual main volume instead.
- **Whether the device is the default output.** If it isn't, `osascript set volume` doesn't reach it.

**One round trip, then check the DDC/CI mirror.** This is the only write in this phase, and it is fully reversible:

1. Note each channel's level in dB from `audioprobe`.
2. Change the level. `tools/macos-probe/hpvolume` does it for the HP; for another monitor, change the device name on its line 57.
3. Read `./glim get 62` and `./glim get 8D`.
4. Restore the exact level in dB (`hpvolume db <dB>`). A 0–1 scalar can only land on a coarse step.

On the HP, 0x62 followed the USB level, but 0x8D did not follow the USB mute.

If a level drifts and you don't know why, macOS logs every volume write together with the process that made it:

```sh
log show --last 1h --predicate 'eventMessage CONTAINS "LogVolumeChangeForClientSide"' | grep -i '<model>'
```

## Buttons (HID)

```sh
tools/macos-probe/hidprobe 0x<vendor-id>
```

This decodes the report descriptor without opening the device, so it needs no Input Monitoring permission. Look for:
- **Consumer keys** (volume up and down, mute). macOS applies them to the *default* output, which may not be the monitor.
- **Telephony usages** (mic mute, hook, LEDs).
- **Vendor pages (0xFF00 and above).** These are the vendor's private channel, for firmware updates or configuration. **Never write to them.**

## USB descriptors and webcam

```sh
tools/macos-probe/usbdescprobe 0x<vendor-id>   # or: usbdescprobe all
tools/macos-probe/camprobe
system_profiler SPCameraDataType SPUSBHostDataType
```

- `usbdescprobe` reads the configuration descriptor the Mac already cached. It shows the audio feature units (which controls exist on each channel), a webcam's control bitmaps and formats, and any extension-unit GUIDs.
- A pop-up webcam may only enumerate while it is raised. On the HP, the retracted camera was absent from USB.
- macOS's camera API has no zoom, field-of-view or HDR control. A webcam's brightness, pan/tilt and similar settings are USB video-class requests, out of scope here.

Record all of this in `data/<vendor>-<model>/macos.md`, with the same status markers. `docs/macos-usb-webcam.md` shows what the HP's looked like.
