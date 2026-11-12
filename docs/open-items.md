# Open items

The owner deferred these on 2026-11-04. Each needs either a risky write or someone at the monitor.

[hardware-session.md](hardware-session.md) is the scripted pass through all of them, in order of risk. What could be done without anyone at the monitor was done on 2026-11-12: [`data/safe-probes-2026-11-12.md`](../data/safe-probes-2026-11-12.md).

## Risky writes (need the owner's OK, with a physical fallback ready)

| Item | Why it matters | Risk | Fallback |
| --- | --- | --- | --- |
| **0x60 input switch** to 15 (DP) or 17 (HDMI), then back to 19 (USB-C) | Proves input switching works and shows whether DDC still answers while another input is showing | The screen goes black. DDC may stop answering on the USB-C link. | The monitor's OK / Next Input button |
| **0xD6 power** 02/03 (standby/suspend), 04 (off), 05 (power-button off) | Shows whether DDC can sleep and wake the monitor | ⚠️ The EDID declares active-off only, so standby may act like off. DDC may stop answering. | The power button |
| **0x04 factory reset** | Shows the factory value of every setting | Wipes OSD-only settings that DDC can't read (auto-sleep, LED, function-key assignments, …) | Redo them by hand in the OSD |
| **HP sub-code protocol** ([controls.md § 6](controls.md#6-hp-sub-code-protocol)): verify with `hp-string F5 0D`, then `hp-get E1 0F`, then a round trip with `hp-set E1 0F` | Unlocks reading and writing about 40 HP controls: color preset, response time, auto-sleep, USB-C mode, audio preset, noise cancellation, OSD layout, and the identity strings | Every call, even a read, is a Set to a vendor code. A wrong guess about the encoding writes an unintended value. | Factory reset from the OSD |
| **USB 3 on the hub** (`hp-set E1 39 09`) | The hub currently runs at USB 2.0 because DisplayPort uses all 4 lanes. 09 should give 2 DP lanes plus USB 3, which has enough bandwidth for 1440p75. | The link retrains, and the screen may drop out | Replug the cable; `hp-set E1 39 08` reverts it |
| **The unexplained HP codes** (`E1`/0A 56 57 6F 72, `E8`/1B 1C, `EE`, `E9`) | Not in HP's tables. They may cover the webcam, mic, LED or function keys. | Unknown effects | Factory reset from the OSD |
| **0x0C (DDC command) save current settings** | Shows whether DDC writes survive a power cycle without it | Low | — |

## Checks that need someone at the monitor

- [ ] **Watch the screen during each write.** Record what 0x2E, each 0x14 preset value (06/07/0A/0C/0D in particular), 0x86, 0x87 and the black levels look like.
- [ ] **Map 0x14 read values to OSD names.** Cycle the presets through DDC while the OSD Color menu is open. Candidates: Warm, Neutral, Cool, Native, sRGB, Low Blue Light, Reading, Night, HP Enhance+, Custom RGB. Until then the app offers only sRGB, native, 5000 K, 6500 K and 9300 K, the presets the read-backs pin down; 03, 06/07, 0A and the user presets would join once someone has seen them.
- [ ] **Color, by eye.** ✅ The app's color controls pass `make hardware-test` (2026-11-12, read-backs): a pick is checked against 0x0C, which gets the monitor out of the custom temperature state the first run found ([`data/safe-probes-2026-11-12.md`](../data/safe-probes-2026-11-12.md)). Still for someone at the monitor: what the screen shows at, say, 0x14 = 1 with 0x0C = 55, and whether picking sRGB from a custom temperature visibly passes through 6500 K.
- [ ] **0x0C stuck at 70.** At the start of that session 0x0C read 70 under every preset until the first 0x0C write. Power-cycle the monitor, then read `glim get 0C` under sRGB (`glim set 14 1`) to see whether a power cycle is what does it.
- [ ] **Automatic brightness on the hardware** (issue #4's acceptance). ✅ On an AOC U34G2G4R3, 2026-11-09, it set 55% at 19 lux, the curve's value, and idled at 0.03% CPU with it on and the window open. Still to do: dim the room and time how long the display takes to follow (target: about 10 s, no visible stepping); move the slider and check it holds and is learned; close the lid and check the schedule takes over.
- [ ] **RGB gains (0x16/0x18/0x1A).** Decide whether to offer them. Any gain write switches the preset to Custom RGB, and only `0x14 ← 05` switches it back.
- [ ] **Watch 0x02 / 0x52 (new-control-value / active-control).** Change a setting with the buttons, then run `glim get 02` and `glim get 52`. If 0x02 reads 2 and 0x52 names the changed code, a host can follow OSD changes.
- [ ] **Map the readable HP codes.** Change one OSD setting at a time and re-scan with `glim scan`, diffing against `data/scan-all.txt`. This shows which OSD item each of E6/E7/E9/EA/EE/EF/F0/FA/FB/FC/FD/FE tracks.
- [ ] **Front-panel keys.** Press mic-mute and re-run `tools/macos-probe/audioprobe HP` to see whether input mute flips in hardware. Press volume +/- and check whether the MacBook speakers or the HP's USB volume change.
- [ ] **Webcam.** Pop it up, then run `system_profiler SPCameraDataType SPUSBHostDataType`, `usbdescprobe` and `camprobe`. That gives the product ID, UVC controls, formats and IR function.
- [ ] **OSD Management menu.** Look for a DDC/CI on/off switch, a USB-C "data vs resolution" (USB 3) option and the auto-sleep timer. Note where each one lives.
- [ ] **Scaling and sidetone, seen and heard.** 0x86 stores 02 and 05 at 1920×1200, and the sidetone volume (USB feature unit 9) can be set with `tools/macos-probe/uacprobe`; both were checked by read-back only. Someone has to look at 02 against 05, and listen to the sidetone above its −69 dB floor.

## Not yet tried

- [ ] **UVC GET/SET on the webcam** once it enumerates.
