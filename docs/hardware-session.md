# Hardware session: the open items that need someone at the monitor

One scripted pass through [open-items.md](open-items.md) for the HP E27m G4, ordered from least to most risky. It follows the rules of [exploration/README.md](exploration/README.md): read before you write, check the read-back and not the write, one DDC/CI client at a time, never write to discover, and prove the restore at the end.

**Every step that writes is run only after the owner says so, for that step, in the session.** Stop at the first surprise: an unexpected read-back, a screen that does something the step doesn't describe, or a scan diff that shows a code this page doesn't mention.

Status: prepared 2026-11-12, not yet run. Nothing below is verified.

## Before starting

Physical fallbacks to have in reach, and to find in the OSD before step B1:

| If… | Do |
| --- | --- |
| the screen is black after an input switch | press the monitor's **OK / Next Input** button |
| the monitor is off | press its **power** button; if it does nothing, hold it 10 s (that also clears a power-button lock) |
| DDC/CI stops answering | OSD › **Management › DDC/CI › On** |
| the USB-C link doesn't come back | unplug and replug the USB-C cable |
| settings are in a state nobody understands | OSD › **Management › Factory Reset** (last resort: it wipes OSD-only settings) |

```sh
cd ~/Documents/private-repositories/Glim
make glim probes
osascript -e 'tell application id "io.github.malclement.Glim" to quit'
ps axo comm | grep -i -E 'glim\.app|monitorcontrol|betterdisplay|lunar|m1ddc'   # must print nothing
mkdir -p /tmp/glim-session && S=/tmp/glim-session
snap() { ./glim scan --all > "$S/$1.txt"; diff data/scan-all.txt "$S/$1.txt" | grep '^>'; }
./glim list                      # exactly one external display: the CLI takes the first it finds
tools/macos-probe/hpvolume db -18.03
snap before                      # expect one line: 0xC0 (usage hours)
```

At the monitor, before any write: open the OSD and note (on paper or a photo, not in the repo) the **Information** page (model, firmware, serial), every item of the **Management** menu, the **Power** menu's Auto-Sleep Mode, the three function-button assignments, and whether Management or Input has a USB-C configuration item. A factory reset would wipe these.

## A. Observation: no risky writes

Steps A1–A5 send nothing but Gets. A6 and A7 write codes verified as safe on 2026-11-04 and 2026-11-12.

| # | Command | At the monitor | Expected | If it goes wrong | Restore |
| --- | --- | --- | --- | --- | --- |
| A1 | `./glim get 02; ./glim get 52; ./glim get 52; ./glim get 10` | First lower the brightness two steps with the monitor's buttons, then say so. Repeat with a Color preset change and a volume key. | If the monitor reports OSD changes: 02 reads 2, the first 52 reads 16 (0x10), the second 0. If 02 stays 1, there is no change notification and Glim can't follow the OSD without polling. | — | Put the brightness back with the buttons. If 02 read 2, clearing it is step A1b. |
| A1b | `./glim set 02 1` | nothing | reads back 1. MCCS has the host write 1 to acknowledge. Only run if A1 read 2. | The flag stays 2: harmless. | — |
| A2 | `snap a2-<item>` after each change | Change **one** OSD setting at a time: Input › Auto-Switch Input, Image › Dynamic Contrast, Power › Power Mode, Management › anything with three choices, the power LED, each function button. Say what you changed. | One changed line per item. This maps E6, E7, E9, EA, EE, EF, F0 to OSD items; EE (1–3, now 2) and E9 are the unexplained ones. | A line changes that the item shouldn't explain: note it, carry on. | Put each item back, then `snap a2-end`: only 0xC0. |
| A3 | `tools/macos-probe/audioprobe HP \| grep -E 'mute\|volume'` and `tools/macos-probe/hpvolume`, before and after | Press the mic-mute key, then volume up, volume down, speaker mute. | Shows whether each key changes the HP's USB device in hardware, or only sends a media key that macOS applies to the default output. | — | `tools/macos-probe/hpvolume db -18.03`; press mic-mute and speaker mute again. |
| A4 | `system_profiler SPCameraDataType SPUSBHostDataType; tools/macos-probe/usbdescprobe 0x03f0; tools/macos-probe/camprobe; snap a4` | Pop the webcam up. | A new USB device on the internal hub, its UVC controls and formats. The scan shows whether any DDC code follows the camera. Keep serial strings out of anything saved to the repo. | — | Push the webcam back down. |
| A5 | `ioreg -r -c DCPAVServiceProxy -l \| grep -E 'Location\|IORegistryEntryID'` then `time ./glim get 10`, before and after each event | One at a time: unplug and replug the cable; power the monitor off and on with its button; put the Mac to sleep and wake it; close and open the lid. | For each: does the proxy come back with a new registry ID, and how many seconds until `get 10` answers. After the power cycle also run `./glim set 14 1; ./glim get 0C; ./glim set 14 5`: 0x0C should read 0 under sRGB; if it reads 70, a power cycle is what causes the stuck read of 2026-11-12. | `get 10` never answers: check DDC/CI in the OSD. | — |
| A6 | `./glim set 14 N; ./glim get 14; ./glim get 0C` for N = 1…13 | Keep the OSD **Color** menu open; read out the highlighted name and say what the picture does. | The read-backs of the [0x14 table](controls.md#0x14-color-preset-mapping), now with an OSD name each. Then the custom state: `./glim set 0C 55; ./glim set 14 1` reads (1, 55): is the picture sRGB or 5750 K? | — | `./glim set 0C 70; ./glim set 14 5`, then (8, 70). |
| A7 | `tools/macos-probe/displaymode set 1920 1200 60; ./glim set 86 5; ./glim set 86 2` · `./glim set 2E 3; ./glim set 2E 0` · `./glim set 87 7; ./glim set 87 4` | Say what the picture does at each write. Windows on the HP are resized by the mode change. | 86: 05 fills the panel, 02 keeps 16:10 with bars. 2E: dark greys lift. 87: edges sharpen. | The mode doesn't come back: System Settings › Displays. | `tools/macos-probe/displaymode set 2560 1440 75`; then `snap a7`: only 0xC0. |

## B. HP sub-code protocol

This comes early because it unlocks about 40 controls. Every command here, the reads too, begins with a Set to a vendor code ([controls.md § 6](controls.md#6-hp-sub-code-protocol)). The order is built so that each step proves the next one safe.

**The rule for this block.** A read is `Set(code, 0x8000 | sub << 8)` followed by a Get. If this firmware ignored the top bit, that Set would be a *write of value 00* to the sub-code. So until B3 has proved that a read does not write, only sub-codes where 00 is harmless are read. **`hp-get E1 04` (00 = DDC/CI off) and `hp-get E1 27` (reset actions) are never run at all**, and `hp-get E8 18` (00 = power button locked) waits for B4.

| # | Command | At the monitor | Expected | If it goes wrong | Restore |
| --- | --- | --- | --- | --- | --- |
| B1 | `./glim -v --force hp-string F5 0D` | Nothing should change. | `0xF5/0D "HP E27m G4"`. F5 holds read-only identity strings, so even a misread write does nothing. | Empty, garbage or `no-reply`: **stop block B**, the protocol is not what HP's tables say. `snap b1`. | none needed |
| B2 | `./glim --force hp-string F5 1C`; same for `0E 0F 12 13 15 19 1B 1E` | Compare 1C and 1E with the OSD Information page. | Firmware package, panel, hub, scaler and webcam strings. **Not `F5 0C`**: that is the serial number. | A string that doesn't match the OSD: note it, carry on. | none |
| B3 | `./glim -v --force hp-get E1 0F` | **Before:** OSD › Power › Auto-Sleep Mode must show **On** (turn it on by hand if not). **After:** look again. | `value=1`, and the OSD still shows On. That proves a read-select does not write. | The OSD now shows Off: the read wrote 00. **Stop block B.** | Auto-Sleep back On in the OSD |
| B4 | `./glim --force hp-set E1 0F 00; ./glim --force hp-get E1 0F` then `./glim --force hp-set E1 0F 01; ./glim --force hp-get E1 0F` | After each pair, read out Power › Auto-Sleep Mode. | `value=0` and Off, then `value=1` and On. This is the first verified vendor write. `snap b4`: only 0xC0. | The OSD and the read disagree: stop. | `hp-set E1 0F 01`, or the OSD |
| B5 | `for s in 0C 10 35 36 39 3B 3C 3E 3F 40 42 43 45 49 4A 4C 6B 6C 6E 73; do ./glim --force hp-get E1 $s; done; ./glim --force hp-get DC 00; ./glim --force hp-get EB 00; ./glim --force hp-get E8 18; ./glim --force hp-get E8 1E; ./glim --force hp-get F8 00; ./glim --force hp-get F8 01` | Check three or four against the OSD: Power Mode, Response Time, the Color preset, OSD timeout. | A value for each sub-code the capabilities string lists and HP's tables explain. E1/39 says which USB-C mode is set (expected 08). E8/18 should read 1. `snap b5`: only 0xC0. | Any `unsupported` or a value outside the listed ones: note it. | none |
| B5b | `for s in 0A 56 57 6F 72; do ./glim --force hp-get E1 $s; done; ./glim --force hp-get E8 1B; ./glim --force hp-get E8 1C` | Nothing should change. | Current values of the sub-codes no source explains. **Reads only: they are never written** unless A2 or the OSD shows what they are. | `snap b5b` shows a change: stop. | none |
| B6 | For each of: audio preset `E1 6B` (00 Music, 01 Movie, 02 Voice) · response time `EB 00` (01–05) · HP color preset `DC 00` (15 Neutral → 13 Warm) · power mode `E1 36` (00 Power Saver, 01 Performance) · mic noise cancellation `E1 6C` (00/01): `hp-get`, `hp-set` to another listed value, `hp-get`, then `hp-set` the original, `hp-get` | After each write, read out the matching OSD item. For `DC 00` also run `./glim get 14; ./glim get 0C`: that ties HP's preset names to the MCCS read-backs. | Each reads back what was written and the OSD agrees. These are the controls Glim would offer. | A value doesn't take: note it; it stays 📄. | the original value, then `snap b6`: only 0xC0 |
| B7 | `./glim --force set EA 1; ./glim --force set EA 0` · `./glim --force set E6 0; ./glim --force set E6 1` | Image › Dynamic Contrast, Input › Auto-Switch Input. | Flat HP codes: plain Set and Get. With dynamic contrast on, check whether `./glim set 10 50` still works. | — | EA 0, E6 1 |

## C. Writes that drop the picture or the link

Run these only after block B, with the cable and the buttons in reach. Expect macOS to rearrange windows each time the display goes away.

| # | Command | At the monitor | Expected | If it goes wrong | Restore |
| --- | --- | --- | --- | --- | --- |
| C1 | `./glim --force hp-get E1 39` then `./glim --force hp-set E1 39 09`, wait 10 s, `ioreg -r -c AppleHPMInterfaceType10 \| grep TransportsActive; tools/macos-probe/displaymode current; ./glim list; ./glim get 10; ./glim --force hp-get E1 39` | The picture may drop for a few seconds. HP's guide says to replug the cable afterwards. | `TransportsActive` gains `USB3` and DisplayPort drops to 2 lanes; the mode is still 2560×1440 @ 75 Hz; DDC answers. Then decide: keep 09 (USB 3 on the hub) or go back. | No picture after 30 s: replug the cable. Still none: OSD › Management, or plug into another input and use the OSD. | `./glim --force hp-set E1 39 08`, replug, check `TransportsActive` |
| C2 | `( for i in 1 2 3 4 5 6 7 8; do sleep 2; date +%T; ./glim get 60; done; ./glim --force set 60 19 ) & ./glim --force set 60 17` | Say what is plugged into HDMI and DisplayPort first. The screen goes black or shows "no signal". Don't touch anything for 20 s: the background loop reads 0x60 every 2 s, then writes USB-C (19) back. | Shows whether DDC still answers while another input is selected, whether Auto-Switch (E6 = 1) falls back by itself, and whether the write back lands. Repeat with `set 60 15` (DisplayPort). | Still black after 30 s: press **OK / Next Input** until USB-C is back. | `./glim get 60` reads 19; `snap c2`: only 0xC0 |
| C3 | `./glim --force set D6 2`, then every 3 s for 15 s `./glim get D6`, then `./glim --force set D6 1`. Then the same with 3, then 4, then 5. | Watch the power LED and the picture at each value. | Whether standby and suspend differ from off (the EDID declares active-off only), whether DDC still answers in each state, and whether `D6 ← 1` wakes it. | It doesn't wake: move the mouse; then the power button. After 05 the button may be the only way. | `./glim get D6` reads 1; `snap c3`: only 0xC0 |
| C4 | `./glim set 10 90; ./glim --force save`, power-cycle the monitor, `./glim get 10` | Power the monitor off and on with its button. | 90 either way; compare with the same cycle without `save`. Low value: settings already persist. | — | `./glim set 10 100` |

## D. Not recommended

| Item | Why it is here |
| --- | --- |
| `./glim --force set 04 1` (restore all factory defaults) | It shows every factory value but wipes OSD-only settings DDC can't read back: function buttons, auto-sleep, LED, the USB-C mode from C1. Only with the notes from "Before starting" in hand, as the very last step, followed by putting each setting back. |
| Writing the unexplained codes (`E1` 0A 56 57 6F 72, `E8` 1B 1C, `EE`, `E9`) | No source says what they do. Rule 3: never write to discover. They are read in B5b and correlated with the OSD in A2; a write is only worth planning once one of those names it. |
| `hp-set E1 04 00`, `hp-set E1 27 0A`, `hp-set E8 18 00`, `FA`–`FE` | DDC/CI off, master reset, power-button lock, theft deterrence. Never. |

## Closing the session

```sh
./glim set 14 5; ./glim set 0C 70; ./glim set 10 100; ./glim set 12 100
tools/macos-probe/hpvolume db -18.03
tools/macos-probe/displaymode current        # 2560x1440 @ 75 Hz
snap after                                   # only 0xC0 may differ
./glim get 62; ./glim get 8D                 # 30 and 2
open /Applications/Glim.app
```

Anything else in the diff is restored before stopping, and written down. Then each finding moves its row in [controls.md](controls.md) from 📄 to ✅ with the wire sequence used, [open-items.md](open-items.md) loses the item, and a control that is now verified and safe goes into the HP profile with fixtures and tests ([exploration/07-into-glim.md](exploration/07-into-glim.md)).
