# HP E27m G4: every DDC/CI control

This is the complete catalog of what a host can change or read on this monitor over DDC/CI. The unit tested was firmware 1.0, MCCS 2.2, connected over USB-C. Controls that live outside DDC (resolution, USB audio, the webcam, front-panel keys) are covered in [macos-usb-webcam.md](macos-usb-webcam.md).

**How the list was built and how far it can be trusted**

1. **Capabilities string.** The monitor's own self-description ([`data/capabilities.txt`](../data/capabilities.txt)).
2. **Full GET scan of all 256 codes.** Every code answered with either `ok` (49 codes) or `unsupported` (207). None failed to reply, so the set of plainly readable codes is complete ([`data/scan-all.txt`](../data/scan-all.txt)).
3. **Set, read back, restore** on every standard code that is safe to write, with diffs of all 49 readable codes ([`data/write-tests-2026-11-04.md`](../data/write-tests-2026-11-04.md)).
4. **Standards.** VESA MCCS 2.2a and DDC/CI 1.1 for the standard codes.
5. **HP's own control tables**, read out of HP Display Center 2.4.4.7 (Windows). The app was taken apart, not run. Its tables give every HP feature name, VCP code, sub-code and value name, and they are the only source for the HP-specific codes below. The tables themselves are HP's and are not included in this repository.

**Status markers**

- ✅ **verified**: written and read back on this unit, with effects confirmed by read-back.
- 👁 **read only**: the current value was read and decoded, but not written.
- 📄 **documented**: from MCCS or HP's tables; not exercised on hardware.
- ❓ **unknown**: no source explains it.
- ⚠️ **hazard**: can blank the screen, cut off DDC, or wipe settings. See [§ Hazards](#hazards).

**Is this exhaustive?** It covers everything the firmware lists, everything that answers a GET, and every HP feature this model's capabilities string names. Anything beyond that would be an undocumented write-only code that is neither listed nor readable, and can only be found by blind writes. MCCS itself warns against that.

---

## 1. Picture

| Code | Control | Values | Now | Status | How it behaves |
| --- | --- | --- | --- | --- | --- |
| `10` | **Brightness** (backlight) | 0–100 | 100 | ✅ | Real backlight dimming; macOS can't do this for an external display. The factory default is 80, as shown by reset 0x05. |
| `12` | **Contrast** | 0–100 | 100 | ✅ | Factory default 100. |
| `16` `18` `1A` | **Red / green / blue gain** | 0–255 | 255 | ✅ | Range is 0–255 here, not 0–100. **Any gain write switches the preset to Custom RGB** (0x14 reads 15). Restoring the gains doesn't switch it back; `set 14 5` does. |
| `6C` `6E` `70` | **Red / green / blue black level** | 0–255 | 128 | ✅ | 128 is the midpoint. Writing it doesn't affect the preset. |
| `0C` | **Color temperature** | 0–126 | 70 | ✅ | Kelvin = 3000 + value × 50 (the step size comes from `0B`). Any value is accepted: 70 = 6500 K, 126 = 9300 K, 55 = 5750 K. 0 reads as Custom. |
| `0B` | Color temperature step | — | 50 | 👁 | Read-only: 50 K per step. |
| `14` | **Color preset** (MCCS) | write 01–0D | reads 8 | ✅ | Writes use MCCS values; reads come back in HP's own numbering. See [§ 0x14 mapping](#0x14-color-preset-mapping). **Factory setting: write 5 (6500 K).** |
| `DC`/`00` | **Color preset** (HP) | 00 Native, 12 Night, 13 Warm, 14 Cool, 15 Neutral, 1D HP Enhance+, 1E Custom RGB | ? | 📄 | HP's native preset control. Needs the HP sub-code protocol (§ 6). Low Blue Light and Reading appear in the OSD but are **not** in this model's capabilities string, so DDC can't select them. |
| `87` | **Sharpness** | 1–7 | 4 | ✅ | Out-of-range values (0, 8) are ignored. |
| `2E` | **Black Stretch** (MCCS "gray scale expansion") | SL 0 Off, 1 Low, 2 Medium, 3 High | 0 | ✅ | Stores 0–3 and changes no other code. Per MCCS 2.2a, SH would hold a near-white level, which this monitor doesn't list. The visible effect wasn't observed. |
| `EA` | **Dynamic contrast** | 0 off, 1 on | 0 | 👁📄 | HP flat code. Not written. |
| `EB`/`00` | **Response time** (overdrive) | levels 01–05 | ? | 📄 | HP sub-code. HP's level 00 (Off) isn't offered on this model. |
| `86` | **Scaling** | 02 fill to aspect ratio, 05 fill to screen | 2 | ✅ ignored | Every write is ignored at the native 2560×1440 input. ⚠️ Probably only applies to non-native timings (open item). |
| `DA` | Scan mode | 0 normal, 1 underscan, 2 overscan | 0 | 👁 | Not in the capabilities string; not written. |
| `E1`/`4E` | **Full-screen test pattern** | 00 black, 01 50% grey, 02 white, 03 red, 04 green, 05 blue, FF (probably off) | — | 📄⚠️ | Fills the screen. |
| `E1`/`4C` | User burn-in mode | 0/1 | ? | 📄 | |

### 0x14 color-preset mapping

Measured on this unit; each reading was stable over three reads.

| Write | MCCS meaning | Reads back | 0x0C reads |
| --- | --- | --- | --- |
| 01 | sRGB | 1 | 0 |
| 02 | native | 10 | 0 |
| 03 | 4000 K | 3 | 0 |
| 04 | 5000 K | 5 | 40 (5000 K) |
| **05** | **6500 K** | **8** | **70 (6500 K)**, factory setting |
| 06 / 07 | 7500 K / 8200 K | 6 | 0 |
| 08 / 09 | 9300 K / 10000 K | 2 | 126 (9300 K) |
| 0A | 11500 K | 11 | 0 |
| 0B | user 1 | 15 | 0 (Custom RGB) |
| 0C | user 2 | 2 | 0 |
| 0D | user 3 | 4 | 0 |

**How to read this table**

- The read-back is HP's internal preset index, not the MCCS value. The agent's reading of HP's tables (*read 8 = 9300 K*) is wrong for this monitor; read 8 is 6500 K, as the 0x0C reading confirms.
- **0x0C is the reliable read-out for Kelvin.** Setting 0x0C directly also moves the 0x14 read-back: 40 reads 5, 55 reads 8, 100 reads 2, 0 reads 15.
- Matching the read values to OSD names (Warm, Neutral, Cool, Native, sRGB, Night, HP Enhance+, Custom) needs someone at the OSD. That is an open item.

## 2. Input

| Code | Control | Values | Now | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `60` | **Input source** | `0F` DisplayPort, `11` HDMI, `13` USB-C | **0x13 (19), USB-C** | 👁 ⚠️ | 0x13 is HP's USB-C value; MCCS 2.2a reserves values from 0x13 up. **Not written** (deferred). Switching to a port with nothing plugged in blanks the screen. |
| `E6` | **Auto-switch input** | 0 off, 1 on | 1 | 👁📄 | With it on, the monitor should fall back to an active input ⚠️. |
| `E7` | Hot-plug detection | 0 low power, 1 always active | 1 | 👁📄 | |
| `E1`/`04`=`08` | Jump to next active input | — | — | 📄⚠️ | A soft-key action. |
| `E1`/`35` | **DisplayPort mode** | 00 DP 1.1, 01 DP 1.2 | ? | 📄⚠️ | Can retrain the link. |
| `E1`/`39` | **USB-C configuration** | `08` video + USB 2.0, `09` video + USB 3.0 | ? | 📄⚠️ | **Explains the USB 2.0 hub.** The link uses 4 DisplayPort lanes, so the monitor is almost certainly set to 08. Setting 09 should give 2 DP lanes plus USB 3; 2560×1440 @ 75 Hz needs about 7.1 Gbps, which fits in 8.64. HP's guide says to replug the cable afterwards. Untested. |
| `E1`/`49` | USB-C "Microsoft OS" messages | 0/1 | ? | 📄 | |

## 3. Audio

| Code | Control | Values | Now | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `62` | **Speaker volume** | 0–100 | 30 | ✅ **read-only mirror** | DDC writes are accepted but ignored. The value **follows the USB Audio output volume** set from the Mac (non-linear, follows the dB curve): 0.25 → 9, 0.5721 (−18.03 dB) → 30, 0.89 → 77. To change the level, use CoreAudio (`tools/macos-probe/hpvolume`). |
| `8D` | **Mute** | SL 1 mute, 2 unmute | 2 | ✅ | The max field says screen blanking (SH) is **not** supported. |
| `E1`/`6B` | **Audio preset** | 00 Music, 01 Movie, 02 Voice | ? | 📄 | |
| `E1`/`6C` | **Mic noise cancellation** | 0 off, 1 on | ? | 📄 | |
| `E1`/`73` | Audio menu | 0 disabled, 1 enabled | ? | 📄 | |
| `E1`/`6E` | Audio DSP maker | 00 = Synaptics | — | 📄 | Information only. |

## 4. Power

| Code | Control | Values | Now | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `D6` | **Power mode** | 01 on, 02 standby, 03 suspend, 04 off, 05 off (as if the power button were pressed) | 1 | 👁 ⚠️ | Not written (deferred). The EDID declares active-off only. 05 may need the physical button to recover. |
| `E1`/`0F` | **Auto-sleep** | 0 off, 1 on | ? | 📄 | The best first target for testing the HP protocol: harmless and reversible. |
| `E1`/`10` | Power-on recall | 0/1 | ? | 📄 | |
| `E1`/`36` | **Power mode** | 00 Power Saver, 01 Performance | ? | 📄 | Performance keeps USB powered while the monitor sleeps. |
| `E1`/`0C` | Power Delivery | listed value: 0x20 | ? | 📄❓ | HP's table has 00/01; 0x20 is unexplained. |
| `E8`/`18` | **Power-button lock** | 00 locked, 01 enabled | ? | 📄⚠️ | Recover with `hp-set E8 18 1`, or hold the power button for 10 s. |
| `EF` + `F0` | Power-consumption log | EF selects slot 1–5; F0 holds the value | EF 0x0505, F0 4900 | 👁📄 | ⚠️ Units unknown; 4900 might be 49.00 W. |

## 5. OSD (the monitor's menu)

| Code | Control | Values | Now | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `CA` | **OSD lock** | 01 OSD off (buttons still send events), 02 OSD on; (MCCS) 03 OSD and buttons off | 2 | ✅ | DDC still works while the OSD is locked. HP's names for 01 and 02 are swapped relative to MCCS; MCCS is right here. |
| `CC` | **OSD language** | 01 Chinese (traditional), 02 English, 03 French, 04 German, 05 Italian, 06 Japanese, 09 Russian, 0A Spanish, 0D Chinese (simplified), 0E Portuguese (Brazil), 14 Dutch | 2 | ✅ | |
| `E1`/`3B` `3C` | OSD horizontal / vertical position | continuous | ? | 📄 | |
| `E1`/`3E` | OSD timeout | continuous | ? | 📄 | |
| `E1`/`3F` | **OSD rotation** | 02 0°, 03 90°, 04 180°, 05 270° | ? | 📄 | For portrait use. This rotates the menu, not the image. |
| `E1`/`40` | Status window | off / top / middle / bottom | ? | 📄 | |
| `E1`/`42` `43` `45` `4A` | Power-on logo; "no input" warning; power-mode message; "confirm change" message | 0/1 each | ? | 📄 | |
| `E1`/`04` | **DDC/CI and soft keys** | **00 DDC/CI off** ⚠️, 01 on; 03 open Color menu, 04 open Brightness menu, 06 open Information, 08 next active input, 09 swap power modes, 0A open Volume menu | ? | 📄⚠️ | **00 locks out every DDC tool.** Recover from the OSD: Management → DDC/CI → On. |
| `E1`/`27` | **Menu resets** | 02 Image, 03 Input, 04 Power, 05 Menu, 06 Audio, 07 Management, 09 Brightness, **0A Master Reset** ⚠️, FF exit all menus | — | 📄 | |
| `E8`/`1E` | Text-to-speech (accessibility) | 00 off, 01 on, 02 (not in HP's table) | ? | 📄 | |

## 6. HP sub-code protocol

HP's tables document the protocol. It hasn't been verified on this unit, because the owner deferred all writes to vendor codes, and even a read here starts with a Set.

```
write   Set(code, SH=sub, SL=value)                       glim --force hp-set E1 0F 01
read    Set(code, 0x8000 | sub<<8); wait 200 ms; Get      glim --force hp-get E1 0F    → answer in SL
string  per chunk n: Set(code, 0x8000 | sub<<8 | n); Get  glim --force hp-string F5 0D → 4 ASCII bytes per reply in MH ML SH SL, until 0x00
```

✅ A plain Get of `DC E1 E8 EB F5 F8` returns `rc=01` (unsupported), which is consistent with the monitor waiting for the select write first. ✅ A Get with a sub-code byte appended (`01 E1 04`) is rejected with the error code `BF`.

**Safe first steps when testing resumes:**

1. `hp-string F5 0D`: read the model name. Read-only after the select write.
2. `hp-get E1 0F`: read the auto-sleep setting.
3. `hp-set E1 0F` with the opposite value, read it back, then restore it.

### F5: identity strings (read only)

| Sub | Content | | Sub | Content |
| --- | --- | --- | --- | --- |
| 00 | HP VCP protocol version | | 0E / 0F | Panel maker / part number |
| 01 / 02 / 03 | DisplayPort / HDMI / USB version | | 11 / 12 / 13 | USB hub maker / part number / firmware |
| 05 / 06 | Native resolution X / Y | | 14 / 15 | Scaler maker / part number |
| 0A | Manufacturer ID | | 19 / 1B | Webcam maker / firmware |
| 0C | Serial number | | 1C | Firmware package version |
| 0D | Model name | | 1E | Hardware revision |

### F8: webcam USB identity

`00` USB vendor ID, `01` product ID, `02` feature flags (`02(00)` = face auto-exposure). 📄

### Sub-codes the capabilities string lists that nobody can explain

`E1`/`0A`, `E1`/`56`, `E1`/`57`, `E1`/`6F`, `E1`/`72`, `E8`/`1B`, `E8`/`1C`, flat `EE` (1–3, now 2), and `E9` (reads 1/1; not in the capabilities string). ❓ None of them appears in HP Display Center's tables. Candidates include the webcam, the mic, the power LED and the 3 function-key assignments, but these are guesses.

## 7. Security: anti-theft

| Code | Control | Now | Status |
| --- | --- | --- | --- |
| `FA` | Theft deterrence: 0 off, 1 consumer, 2 enterprise | 0 (off) | 👁📄 |
| `FB` | Theft timeout, in minutes (max 60) | 5 | 👁📄 |
| `FC` / `FD` | Theft PIN, low / high 3 digits | 0 / 0 | 👁📄 |
| `FE` | Theft mode: 0 off, 2 on | 0 | 👁📄 |

- When theft deterrence is on, the monitor dims about 5 minutes after it is connected to a new host unless the PIN is entered.
- The **PIN can be read over plain DDC**. This is the vulnerability [CVE-2023-5449](https://support.hp.com/us-en/document/ish_9438665-9438794-16).
- On this unit theft deterrence is off and no PIN is set.

## 8. Read-only information

| Code | Meaning | Raw | Decoded | Status |
| --- | --- | --- | --- | --- |
| `AE` | Vertical frequency | 7500 | **75.00 Hz** | 👁 |
| `AC` | Horizontal frequency | `MH=00 ML=00 SH=B1 SL=FC` | **111.10 kHz**. ✅ The firmware drops the top byte of the 24-bit value 0x01B1FC; the timing report confirms 111.10 kHz. | ✅ |
| (cmd 07) | Timing report | `4E 02 2B66 1D4C` | 111.10 kHz, 75.00 Hz, H-sync positive, V-sync negative | ✅ |
| `AA` | Screen orientation | 1 | landscape (0°) | 👁 |
| `B2` | Subpixel layout | 1 | RGB vertical stripe | 👁 |
| `B6` | Display technology | 3 | LCD, active matrix | 👁 |
| `C0` | Usage time | 791 → 792 | hours powered on; it ticked over during testing | ✅ |
| `C6` | Application enable key | 0x5A | HP's vendor key (the same on other HP models) | 👁 |
| `C8` | Display controller | 0x8809 / max 0x0027 | SL 0x09 = **Realtek** scaler (also matches the DP sink OUI 00-E0-4C) | 👁 |
| `C9` | Firmware | 0x0100 | 1.0 | 👁 |
| `DF` | MCCS version | 0x0202 | 2.2 | 👁 |
| `02` | New control value | 1 | 1 = no OSD changes pending; 2 = changed (then `52` names the code) | 👁 |
| `52` | Active control | 0 | queue of codes changed from the OSD | 👁 |

## 9. One-shot actions

| Code | Action | Status | Observed |
| --- | --- | --- | --- |
| `05` | Restore factory brightness and contrast | ✅ | Brightness 100 → 80; contrast stayed at 100 |
| `06` | Restore factory geometry | ✅ | no change (an LCD has no geometry) |
| `08` | Restore factory color | ✅ | no change (color was already at factory) |
| `04` | **Restore all factory defaults** | ⚠️ deferred | |
| `E1`/`27`=`0A` | **Master reset** | ⚠️ deferred | |
| cmd `0C` | Save current settings to non-volatile memory | ⚠️ deferred | Settings already persist without it. |

## Hazards

| Write | Effect | Recovery |
| --- | --- | --- |
| `hp-set E1 04 00` | **DDC/CI turns off.** No tool can reach the monitor until it's turned back on. | OSD → Management → DDC/CI → On |
| `set 04 1`, `hp-set E1 27 0A` | Factory reset, including OSD-only settings | Redo the settings by hand |
| `set D6 4` / `set D6 5` | Monitor turns off | Power button |
| `set 60 <empty port>` | Black screen | OK / Next Input button. Auto-switch (`E6`=1) may fall back by itself ⚠️ |
| `hp-set E1 39 …`, `hp-set E1 35 …` | USB-C or DP link retrains or drops | Replug the cable |
| `hp-set E8 18 00` | Power button locked | `hp-set E8 18 01`, or hold the power button for 10 s |
| `set CA 1` / `set CA 3` | OSD or buttons locked | `set CA 2`. ✅ DDC still works while the OSD is locked. |
| `set FA 1`/`2` with a PIN in `FC`/`FD` | Screen dims on a new host | Read the PIN back, then `set FA 0` |
| `hp-set E1 4E …` | Full-screen test pattern | Probably `FF` ⚠️ |

`glim` refuses writes to `04 60 CA D6 DC E0–FF` and all `hp-*` commands unless `--force` is given.

## Sources

- [VESA MCCS 2.2a](https://milek7.pl/ddcbacklight/mccs.pdf) and [VESA DDC/CI 1.1](https://glenwing.github.io/docs/VESA-DDCCI-1.1.pdf)
- [ddcutil](https://github.com/rockowitz/ddcutil): `src/vcp/vcp_feature_codes.c`, which encodes the MCCS value tables
- [HP Display Center 2.4.4 (softpaq sp165504)](https://ftp.hp.com/pub/softpaq/sp165501-166000/sp165504.html): read for its control tables, not run
- [HP E27m G4 user guide](https://media.dustin.eu/media/d200001001545285/e27m-g4-e-series-user-manual.pdf) and [Maintenance & Service Guide](https://h10032.www1.hp.com/ctg/Manual/c07937323.pdf)
- [HP's monitor command set and CVE-2023-5449](https://spaceraccoon.dev/hacking-display-monitors-monitor-command-control-set/), and [HP's bulletin](https://support.hp.com/us-en/document/ish_9438665-9438794-16)
- Other HP monitors, for comparison: [X24c](https://sleeplessbeastie.eu/2022/10/31/how-to-manage-monitor-using-ddc-ci-protocol/), [Z27u G3](https://github.com/ddccontrol/ddccontrol-db/issues/234), [E273q](https://github.com/ddccontrol/ddccontrol-db/issues/68)
