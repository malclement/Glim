# 7. Into Glim

Without a profile, a monitor already gets Glim's generic support: brightness and contrast if they answer a read, plus the inputs and DDC/CI volume its capabilities string lists, all marked untested. A profile replaces that with exactly what phase 4 verified.

## If you don't write code

Open a **Monitor report** issue (the template is in `.github/ISSUE_TEMPLATE/monitor_report.md`). Attach:
- the table of what works in Glim and what doesn't;
- the report from **Copy Diagnostics** in Glim's window, which contains the capabilities string and leaves out serial numbers;
- if you did phases 2–4, the files from `data/<vendor>-<model>/` and the catalog.

## If you do

1. **Fixtures.** Copy `capabilities.txt` and `frames.txt` to `Tests/GlimCoreTests/Fixtures/<vendor>-<model>-capabilities.txt` and `-frames.txt`. Check there are no serials in them.
2. **Protocol tests.** Add cases to `DDCMessageTests` and `CapabilitiesTests` like the HP's:
   - every captured request is reproduced byte for byte;
   - every shifted read is rejected;
   - the capabilities fragments reassemble into the string;
   - the caps parse gives the model, the commands and the expected codes.
3. **A profile** in `Sources/GlimCore/Model/MonitorProfile.swift`:
   - Match on the EDID manufacturer and product code (`vendorID`, `productID`), never on the name.
   - Offer only the controls phase 4 verified. Put any control you include without verifying it in `untested`, so the UI says so.
   - Volume route: `.ddc` if 0x62 really changes the speakers, `.usbAudio(deviceNamePrefix:)` if they are a USB device, and none otherwise.
   - Inputs: the values the caps list, with the names printed on the monitor's ports.
   - Set `ddcHelp` to where the DDC/CI switch lives in this monitor's menu.
   - Add each quirk to the profile's comment, with its evidence (the "stored differently" mappings, ignored codes, coupled codes).
4. **The write allow-list.** `DDCChannel.writableCodes` decides what Glim may ever write. A new control type (colour, sharpness and so on) is added there deliberately, only for codes in the safe tier.
5. **Hardware tests.** `Tests/GlimCoreTests/HardwareTests.swift` targets the HP. Give a new model its own suite, gated by `GLIM_HARDWARE_TESTS`, that:
   - checks discovery and identity;
   - compares the capabilities string with the fixture;
   - round-trips each verified control and restores it, even when an expectation fails.
6. **Run everything:**
   ```sh
   make check
   make hardware-test        # with the monitor connected
   ./glim scan | awk '{print $1, $4}' | diff data/<vendor>-<model>/baseline.txt -   # only counters may differ
   ```
7. **The pull request** says, for each control: verified on the hardware (✅, with the date and firmware version), or offered untested. It links the catalog and the write-test log.

## Checklist

- [ ] `data/<vendor>-<model>/` contains the capabilities string, `scan-all`, the baseline, timing, frames, the write-test log and `macos.md`.
- [ ] `docs/controls-<vendor>-<model>.md` has every code marked ✅ 👁 📄 ❓ or ⚠️.
- [ ] Nothing committed contains a serial number, display UUID or Mac identifier.
- [ ] The monitor ended at its baseline (only counters differ).
- [ ] The fixtures and protocol tests are added.
- [ ] The profile is added, with untested controls marked.
- [ ] A hardware-test suite for the model exists.
- [ ] `make check` passes.
