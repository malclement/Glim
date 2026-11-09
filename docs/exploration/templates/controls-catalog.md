# <Vendor> <Model>: every DDC/CI control

<!-- Copy to docs/controls-<vendor>-<model>.md and fill in. Never record the
     serial number or display UUID. docs/controls.md is the HP E27m G4's catalog,
     a complete example. -->

| | |
| --- | --- |
| EDID | `<MFR>` product `0x<PPPP>`, manufactured <week/year> |
| Firmware | <0xC9 value, decoded> · MCCS <0xDF value> |
| Connection | <USB-C / DisplayPort / HDMI, through what> |
| Mac | <model>, macOS <version> |
| DDC/CI switch in the OSD | <menu path> |
| Date of the survey | <YYYY-MM-DD> |

**Evidence:** `data/<vendor>-<model>/`, which holds the capabilities string, the full scan, the frames, the timing report and the write-test log.

**Status:** ✅ verified (written, read back, diff checked) · 👁 read only · 📄 documented · ❓ unknown · ⚠️ hazard

## Capabilities versus scan

- Readable but not listed in caps: <codes>
- Listed in caps but not readable: <codes>
- Scan totals: <n> ok · <n> unsupported · <n> no-reply

## 1. Picture

| Code | Control | Values / range | Now | Status | How it behaves |
| --- | --- | --- | --- | --- | --- |
| `10` | Brightness | 0–<max> | | | |
| `12` | Contrast | 0–<max> | | | |
| `0C` / `14` | Colour temperature / preset | | | | |
| `16` `18` `1A` | RGB gain | | | | |

## 2. Input

| Code | Control | Values | Now | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `60` | Input source | <from caps, with port names> | | ⚠️ | |

## 3. Audio

| Code | Control | Values | Now | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `62` | Volume | | | | DDC/CI or a mirror of USB audio? |
| `8D` | Mute | | | | |

## 4. Power and OSD

| Code | Control | Values | Now | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| `D6` | Power mode | | | ⚠️ | |
| `CA` | OSD lock | | | | |
| `CC` | OSD language | | | | |

## 5. Vendor codes (0xE0–0xFF)

| Code / sub | Meaning | Values | Source | Status |
| --- | --- | --- | --- | --- |

## 6. Read-only information

| Code | Meaning | Raw | Decoded |
| --- | --- | --- | --- |

## Quirks

- <every "stored differently", "ignored" and coupled-code finding, with evidence>

## Hazards

| Write | Effect | Recovery |
| --- | --- | --- |
