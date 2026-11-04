# Write tests, 2026-11-04

All tests ran on the HP E27m G4 over USB-C, firmware reading 0xC9=256, from an M4 MacBook Air on macOS 26.5. Each test wrote a value, waited 1–1.5 s, and read the code back. For the codes marked "diff", all 49 readable codes were snapshotted before and after the write and compared. Every value was restored afterwards. The monitor was left exactly at the baseline in `scan-all.txt`, apart from 0xC0, the usage-hours counter, which ticks over on its own.

These are read-back results only. Nobody watched the screen, so what each change looked like is not recorded here.

## Baseline (49 readable codes)

```
02=1 04=0 05=0 06=0 08=0 0B=50 0C=70 10=100 12=100 14=8 16=255 18=255 1A=255 2E=0 52=0 60=19 62=30
6C=128 6E=128 70=128 86=2 87=4 8D=2 AA=1 AC=45564 AE=7500 B2=1 B6=3 C0=792 C6=90 C8=34825 C9=256
CA=2 CC=2 D6=1 DA=0 DF=514 E6=1 E7=1 E9=1 EA=0 EE=2 EF=1285 F0=4900 FA=0 FB=5 FC=0 FD=0 FE=0
```

## Accepted, reads back what was written

| Code | Written | Restored to | Notes |
| --- | --- | --- | --- |
| 10 brightness | 60, 90 | 100 | |
| 12 contrast | 80 | 100 | |
| 16 / 18 / 1A gain | 200 | 255 | **Side effect: the color preset becomes custom** (0x14 reads 15, 0x0C reads 0). Restoring the gains does not undo it. Writing 0x14 ← 5 does. |
| 6C / 6E / 70 black level | 100 | 128 | |
| 87 sharpness | 1, 6, 7 | 4 | 0 and 8 are ignored (out of range). |
| 8D mute | 1 | 2 | |
| CC language | 3 (French) | 2 (English) | |
| CA OSD lock | 1 | 2 | ✅ DDC writes to 0x10 still work while it's locked. |
| 2E (unknown) | 1, 2, 3 | 0 | Diff: no other code changes. |
| 0C color temperature | 40, 55, 100, 126, 0 | via 0x14 ← 5 | Any value is accepted. Kelvin = 3000 + 50 × value. 0 makes the preset read custom (15). |

## Accepted, but stored differently from what was written

**0x14, color preset.** Writes take standard MCCS values. Reads come back in an HP-internal numbering. The mapping was stable over three reads per value.

| Write (MCCS meaning) | 0x14 reads | 0x0C reads | Resulting Kelvin |
| --- | --- | --- | --- |
| 01 sRGB | 1 | 0 | — |
| 02 display native | 10 | 0 | — |
| 03 4000 K | 3 | 0 | — (⚠️ not a Kelvin bucket on this monitor) |
| 04 5000 K | 5 | 40 | 5000 K |
| 05 6500 K | **8** | **70** | 6500 K (factory) |
| 06 7500 K | 6 | 0 | — |
| 07 8200 K | 6 | 0 | — (same state as 06) |
| 08 9300 K | 2 | 126 | 9300 K |
| 09 10000 K | 2 | 126 | clamps to 9300 K |
| 0A 11500 K | 11 | 0 | — |
| 0B user 1 | 15 | 0 | custom RGB (the state the gain writes produce) |
| 0C user 2 | 2 | 0 | — |
| 0D user 3 | 4 | 0 | — |

Writing 0x0C directly also moves the 0x14 readback: 40 reads 5, 55 reads 8, 100 and 126 read 2, 0 reads 15. So the 0x14 readback reports a bucket, not the exact setting.

## Accepted on the bus, but ignored

| Code | Written | Stays at | Likely reason |
| --- | --- | --- | --- |
| 86 scaling | 1–6 | 2 | ⚠️ The input is already native 2560×1440, so there's nothing to scale. Retest with a non-native mode. |
| 62 volume | 0, 31, 50, 100 | 30 | ⚠️ Audio comes over USB. Speaker level may follow the USB Audio device volume instead of DDC. |

## One-shot resets

| Code | Diff after writing 1 |
| --- | --- |
| 05 restore brightness/contrast | 10: 100 → **80**. Contrast stays at 100, so the factory defaults are brightness 80 and contrast 100. |
| 06 restore geometry | none (an LCD has no geometry) |
| 08 restore color | none (color was already at factory 6500 K) |

## Not tested, deferred by the owner

0x60 input switch, 0xD6 power standby/off, 0x04 factory reset, every write to 0xE0–0xFF, 0x0C (the save-settings command), and anything that needs someone watching the screen or pressing the monitor's buttons. See `docs/open-items.md`.
