# Exploring a new monitor

This is the procedure that produced everything Glim knows about the HP E27m G4 (`docs/controls.md`, `docs/ddc-ci-protocol.md`, `docs/macos-usb-webcam.md`, `data/`), written so it can be repeated on any other monitor.

At the end you have:
- a catalog of every control the monitor exposes, each marked verified, read only, documented or unknown;
- the raw evidence behind the catalog;
- the monitor's quirks;
- what it takes to support it properly in Glim.

## The phases

| # | Phase | Writes to the monitor? | Needs someone at the monitor? | Time |
| --- | --- | --- | --- | --- |
| 1 | [Prepare](01-prepare.md): build the tools, connect, identify the monitor | no | no | 15 min |
| 2 | [Read-only survey](02-read-only-survey.md): capabilities, full scan, timing, baseline | no | no | 10 min |
| 3 | [Decode](03-decode.md): turn the raw data into a draft catalog | no | no | 1 h |
| 4 | [Write tests](04-write-tests.md): set, read back, diff, restore, safe codes only | yes, reversible | recommended | 1–2 h |
| 5 | [Beyond DDC/CI](05-beyond-ddc.md): USB audio, HID buttons, webcam, EDID, USB-C link | read only, plus one audio round trip | no | 30 min |
| 6 | [Vendor codes](06-vendor-codes.md): the 0xE0–0xFF range and vendor protocols | only with the owner's agreement | yes | varies |
| 7 | [Into Glim](07-into-glim.md): a profile, fixtures and tests | no | no | 1 h |

Phases 1–3 are safe on any monitor and already make a useful [monitor report](07-into-glim.md#if-you-dont-write-code). Phase 4 is where the verified status comes from. Phase 6 is optional and the riskiest.

## Rules that apply throughout

1. **Read before you write.** Every write test starts from a full snapshot of the readable codes, and ends with a diff against it.
2. **Write only codes you understand.** A code goes into a write test only when MCCS or the vendor documents it, and its effect can be undone over DDC/CI. [04-write-tests.md](04-write-tests.md#risk-tiers) lists the tiers.
3. **Never write to discover.** Sending an undocumented code, or a vendor code (0xE0–0xFF), "to see what happens" can turn DDC/CI off, reset the monitor or lock its buttons. MCCS itself warns against it.
4. **Restore everything, then prove it.** The session ends with a full scan identical to the baseline, apart from counters such as usage hours.
5. **Check the read-back, not the write.** DDC/CI writes are not acknowledged. Some monitors accept a write and ignore it, and others store the value differently from what you wrote.
6. **One DDC/CI client at a time.** Quit Glim, MonitorControl, BetterDisplay, Lunar, and any m1ddc or ddcutil script before starting. Two clients interleave on the bus and corrupt each other's replies.
7. **Keep identifiers out of anything published.** Never record the monitor's serial number, display UUID or the Mac's identifiers in the repo. The EDID manufacturer and product code are enough.

## What to keep, and where

For each monitor, create `data/<vendor>-<model>/`, for example `data/dell-u2723qe/`:

| File | From |
| --- | --- |
| `capabilities.txt` | phase 2, `glim caps` |
| `scan-all.txt` | phase 2, `glim scan --all`: the baseline |
| `frames.txt` | phase 2, `glim -v` captures; becomes a test fixture in phase 7 |
| `timing.txt` | phase 2, `glim timing` |
| `write-tests-<date>.md` | phase 4, from [templates/write-test-log.md](templates/write-test-log.md) |
| `macos.md` | phase 5 findings |

The catalog itself goes in `docs/controls-<vendor>-<model>.md`, from [templates/controls-catalog.md](templates/controls-catalog.md). The HP's is `docs/controls.md`, which predates this convention.

## Status markers

Use the same markers as `docs/controls.md`:

| Marker | Meaning |
| --- | --- |
| ✅ verified | written and read back on this unit; side effects checked by a full-scan diff |
| 👁 read only | read and decoded, not written |
| 📄 documented | from MCCS or vendor material, never exercised on the hardware |
| ❓ unknown | listed or readable, but nothing explains it |
| ⚠️ hazard | can blank the screen, cut off DDC/CI or wipe settings |
