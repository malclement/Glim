# Safe probes, 2026-11-12

HP E27m G4 over USB-C, firmware reading 0xC9=256, M4 MacBook Air, macOS 26.5.2. Nobody was at the monitor: every result here is a read-back, never what the screen looked like. Glim.app was quit first, so `glim` and the hardware tests were the only DDC/CI clients.

Only codes already verified as safe were written: 0x10, 0x0C, 0x14, 0x86, and the USB Audio level. No input, power, reset or vendor code was touched.

## Start and end state

`./glim scan --all` at the start and at the end are identical: 256 replies, none missing. Against `scan-all.txt` three codes differ, none because of this session:

| Code | Baseline | Now | Why |
| --- | --- | --- | --- |
| C0 usage hours | 792 | 799 | counter |
| 62 volume | 30 | 0 | the USB Audio level was found at −74.00 dB (scalar 0), not −18.03 dB |
| 8D mute | 2 | 1 | follows from the level, see below |

The USB level was left at −74.00 dB, where it was found.

## 0x8D reads "muted" at the bottom of the USB level

| USB level | 0x62 | 0x8D |
| --- | --- | --- |
| −74.00 dB (scalar 0.0000) | 0 | **1** |
| −73.00 dB | 1 | 2 |
| −70.00 dB | 1 | 2 |
| −60.00 dB | 2 | 2 |
| −40.00 dB | 7 | 2 |
| −18.03 dB | 30 | 2 |

The USB mute was off throughout. So 0x8D does not mirror the USB mute (known), but it does read 1 when the USB level is at its floor.

## Color: 0x0C and 0x14 have a "custom temperature" state

`make hardware-test` ran twice. Brightness, contrast, the drag, capabilities, USB volume and USB mute passed both times. The two color tests did not:

| Run | `everyOfferedPresetIsRecognized` | `temperatureAndPresetThroughTheControls` |
| --- | --- | --- |
| 1 | failed: 0x0C read 70 under sRGB, native, 5000 K and 9300 K | failed: sRGB never read 0x0C = 0; the factory preset left 0x0C at 55 |
| 2 (after the manual writes below) | passed | failed at the last step only: the factory preset left 0x0C at 55 |

Both runs left the monitor at 0x14 = 8, 0x0C = 55 (5750 K), not the factory 6500 K: the tests restore with `0x14 ← 05`, which does nothing there. It was put back by hand with `0x0C ← 70`.

Measured afterwards with the CLI, 0.7 s after each write:

**Buckets.** What 0x14 reads for a hand-set 0x0C, every boundary checked on both sides:

| 0x0C written | 0x14 reads |
| --- | --- |
| 1 – 40 | 5 |
| 41 – 70 | 8 |
| 71 – 126 | 2 |
| 0 | 15 |

**A custom temperature sticks.** After writing a 0x0C value that is not exactly 40, 70 or 126 (and not 0), 0x0C keeps reading that value whatever is then written to 0x14, while the 0x14 read-back does change:

| From | Write | Reads (0x14, 0x0C) |
| --- | --- | --- |
| 0x0C ← 55 | 0x14 ← 05 | (8, 55), not (8, 70) |
| 0x0C ← 55 | 0x14 ← 01 | (1, 55), not (1, 0) |
| 0x0C ← 55 | 0x14 ← 08 | (2, 55), not (2, 126) |
| 0x0C ← 45 | 0x14 ← 04 | (5, 45), not (5, 40) |
| 0x0C ← 100 | 0x14 ← 08 | (2, 100) |

**Leaving it.** Writing 0x0C to 40, 70, 126 or 0 ends the custom state. Presets then read as in the 2026-11-04 table again:

| Sequence | Reads |
| --- | --- |
| 0x0C ← 60, 0x0C ← 70, then 0x14 ← 01 | (1, 0) |
| 0x0C ← 55, 0x0C ← 40, then 0x14 ← 01, 0x14 ← 05 | (1, 0), (8, 70) |
| 0x0C ← 55, 0x0C ← 126, then 0x14 ← 05 | (8, 70) |
| 0x0C ← 55, 0x0C ← 0, then 0x14 ← 05 | (15, 0), (8, 70) |
| five writes 66…70 with no pause, then 0x14 ← 01 | (1, 0) |

**A lone 0x0C write leaves sRGB and native.** From sRGB (1, 0): `0x0C ← 70` reads (8, 70) and `0x0C ← 60` reads (8, 60). From native (10, 0): `0x0C ← 40` reads (5, 40). No `0x14 ← 05` is needed first.

**Not explained.** In run 1 the monitor started at (8, 70) and still read 0x0C = 70 under every preset, as if 70 were a custom value. Hand-setting 70 afterwards never reproduced that. Whatever put it in that state happened before the session (the monitor had been power-cycled and slept since 2026-11-04).

What the screen shows in the custom state, for example at (1, 55), is not known.

## 0x86 scaling works at a non-native resolution

With the Mac sending 1920×1200 @ 60 Hz (`tools/macos-probe/displaymode set 1920 1200 60`; the timing report confirmed 74.10 kHz / 60.00 Hz):

| Write | Reads back |
| --- | --- |
| 86 ← 5 | 5 |
| 86 ← 1 | 5 (ignored: not a listed value) |
| 86 ← 2 | 2 |

At native 2560×1440 every write is ignored (2026-11-04). 0xDA stayed 0 in both modes. 0xAC read 8564 = 0x2174 where the timing report gives 74.10 kHz = 0x012174: the top byte is dropped, as at native resolution. The mode was restored to 2560×1440 @ 75 Hz.

## 0xF0 is not a live power reading

0xEF stayed 0x0505 and 0xF0 stayed 4900 over a minute at brightness 100, 0 (28 s), 50 and 100. Whatever the log holds, it does not follow the backlight in that time.

## 0x02 / 0x52

0x02 = 1 and 0x52 = 0 before and after every DDC write of the session. Writes over DDC don't raise the flag; whether the monitor's own buttons do still needs someone at the monitor.

## Sidetone (feature unit 9), over raw USB Audio requests

`tools/macos-probe/uacprobe` sends class requests on the default pipe without opening the device, so it works while macOS owns it.

| Control | GET_CUR | Range |
| --- | --- | --- |
| unit 9 mute (master) | 0 (not muted) | — |
| unit 9 volume (master) | −69.00 dB | −69.00 … 0.00 dB, 0.50 dB steps |
| unit 2 volume, channel 1 (the speakers, as a cross-check) | −74.00 dB | −74.00 … 0.00 dB, 1.00 dB steps |

`SET_CUR` on the sidetone volume is accepted: −60.00 dB read back, then −69.00 dB restored. So the sidetone exists, is on but at its floor, and a host can set it. What it sounds like was not checked: the speakers were at −74 dB.
