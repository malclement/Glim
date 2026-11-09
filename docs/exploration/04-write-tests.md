# 4. Write tests

This phase turns 👁 and 📄 into ✅. Every write follows the same loop: snapshot, write, read back, diff, restore, check. Ideally someone watches the screen, because read-backs say what the monitor stored, not what it looks like.

## Risk tiers

| Tier | Codes (MCCS) | Rule |
| --- | --- | --- |
| **Safe** | 10 brightness · 12 contrast · 16 18 1A RGB gain · 6C 6E 70 black level · 87 sharpness · 0C colour temperature · 14 colour preset · 2E gray-scale expansion · 8D mute · CC OSD language | Write freely within the range and the caps values, then restore |
| **Caution** | 05 06 08 restore brightness/contrast, geometry, colour · CA OSD lock · 86 scaling · 62 volume | Reversible, but changes several codes or the OSD. Read the notes below first |
| **Hazard ⚠️** | 60 input · D6 power · 04 restore all factory defaults · the `save` command (op-code 0C) · DC and 0xE0–0xFF vendor codes | Only with the owner's agreement, someone at the monitor, and the physical recovery known. `glim` refuses these without `--force` |
| **Never** | any code not documented for this model | Don't write it at all (rule 3) |

What can go wrong with the hazard tier, as seen or documented on the HP:

| Write | Effect | Recovery |
| --- | --- | --- |
| `60` to an empty input | black screen; DDC/CI may stop answering on this link | the monitor's input button |
| `D6` 04 or 05 | the monitor turns off and may not answer DDC/CI again | the power button |
| `04` | factory reset, including OSD-only settings DDC/CI can't read back | redo them by hand |
| vendor "DDC/CI off" (HP: E1/04 = 00) | every DDC/CI tool is locked out | the OSD: Management › DDC/CI › On |
| vendor power-button lock (HP: E8/18 = 00) | the power button stops working | write it back, or hold the button for 10 s |

## Before the first write

1. Re-check the baseline: `./glim scan > /tmp/now.txt` and diff it against `$M/scan-all.txt`. Only counters such as 0xC0, usage hours, may differ.
2. Write down the current value of every code you will touch.
3. Open a log from [templates/write-test-log.md](templates/write-test-log.md).

## The loop, for each code

```sh
M=data/<vendor>-<model>
snap() { ./glim scan | awk '{print $1, $4}'; }   # all readable codes, "0xNN cur=V"

snap > /tmp/before.txt
./glim set 87 6            # write; glim waits and reads back (it retries the read-0-after-set quirk)
sleep 1
./glim get 87; ./glim get 87; ./glim get 87      # stable over three reads?
snap > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt              # side effects on any other code
./glim set 87 4            # restore the original
snap | diff /tmp/before.txt -                    # back to before: must be empty (or counters only)
```

For a continuous control, test at least the low end, the middle and the high end of its range. Also write one value out of range (for example max+1) and check what happens. On the HP, out-of-range writes were ignored.

For each code, the log records:
- the values written and what each read back;
- the full-scan diff;
- what the screen did, if anyone watched;
- one of the four outcomes below.

## The four outcomes

| Outcome | What you see | Example on the HP |
| --- | --- | --- |
| **Accepted** | it reads back what was written; no other code moved | 10, 12, 87, 6C–70, 8D, CC |
| **Accepted with side effects** | it reads back, and the diff shows other codes moved | any RGB-gain write switched 0x14 to Custom RGB. Restoring the gains didn't switch it back; `14 ← 05` did |
| **Stored differently** | it reads back a value other than the one written, consistently | 0x14: writes take MCCS values, reads come back in HP's own numbering. Record the full mapping table |
| **Accepted and ignored** | it reads back the old value | 0x62 (a mirror of the USB audio level); 0x86 (only acts at non-native resolutions) |

Side effects are why the full-scan diff is not optional. A read-back of the written code alone would have missed every one of the HP's coupled codes.

## Notes on the caution tier

- **05, 06, 08** are one-shot actions: write 1. Diff afterwards, because they reveal factory defaults. 05 took the HP's brightness from 100 to 80, its factory value.
- **CA** (OSD lock): check that DDC/CI writes still work while the OSD is locked, then unlock (write 2). MCCS and some vendors disagree on what 1 and 2 mean; trust the read-back and the screen.
- **86** (scaling) often does nothing at the native resolution. Test it again at a non-native mode if it matters.
- **62** (volume): find out first whether the speakers are a USB device ([phase 5](05-beyond-ddc.md)). If they are, DDC/CI volume may be a read-only mirror.

## Quirks the tools already handle

You will see these in `-v` output; none of them is a failure:
- A read right after a write can return 0. `glim set` waits 200 ms and reads again; the app retries up to twice.
- Every frame is written twice, 10 ms apart, because the display coprocessor sometimes drops one.
- Shifted reads are rejected and retried.

## Closing the session

```sh
./glim scan | awk '{print $1, $4}' | diff $M/baseline.txt -
```

Only counters (usage hours) may differ. If anything else does, restore it before you stop, and record in the log what happened. Then update the catalog: every code you tested goes to ✅, with its behaviour in one line.
