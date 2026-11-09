# 3. Decode

Turn the capabilities string and the scan into a draft catalog. Copy [templates/controls-catalog.md](templates/controls-catalog.md) to `docs/controls-<vendor>-<model>.md` and fill it in as you go. Every entry starts as 👁 read only or 📄 documented; phase 4 promotes the ones you verify.

## References

- **VESA MCCS 2.2a** defines every standard code (0x00–0xDF), its type and its values. `docs/controls.md` links a copy under "Sources".
- **ddcutil**'s `src/vcp/vcp_feature_codes.c` encodes the MCCS value tables in a searchable form.
- **The monitor's user guide** names the OSD controls and gives the factory defaults.
- **The vendor's own control software**, for the vendor range: see [06-vendor-codes.md](06-vendor-codes.md).

## Read the capabilities string

Split it into its fields. For example `cmds(01 02 03 07 0C E3 F3)` lists the op-codes, which are, in order: Get, Get reply, Set, timing, save settings, capabilities reply, capabilities request.

Inside `vcp(...)`:
- `10 12` are codes with no value list, usually continuous controls.
- `60(0F 11 13)` is a non-continuous code with its allowed values: here, the three inputs.
- `E1(04(00 01) 0F(00 01))` is **nested**: a vendor code with sub-codes, each with its own values. ddcutil and ddccontrol reject this syntax ("invalid CAPS"); Glim's parser (`MonitorCapabilities`) reads it, and its tests show the shapes it accepts.

To see how Glim itself parses the string, copy it into the test fixtures and add a case to `Tests/GlimCoreTests/CapabilitiesTests.swift`, the way `parsesTheHPString` does ([phase 7](07-into-glim.md)). Then `swift test --filter CapabilitiesTests`.

## Reconcile caps with the scan

Make two lists and record both in the catalog:

```sh
M=data/<vendor>-<model>
grep ' ok ' $M/scan-all.txt | awk '{print $1}' | sed 's/0x//' | sort > /tmp/readable
# The codes listed in caps (first level), uppercase hex:
python3 -I -c 'import re,sys; s=open(sys.argv[1]).read(); v=s[s.index("vcp(")+4:]
depth=0; out=[]; tok=""
for ch in v:
    if ch=="(":
        depth+=1
    elif ch==")":
        if depth==0: break
        depth-=1
    elif depth==0 and ch.isalnum(): tok+=ch; continue
    if tok and depth<=1 and len(tok)==2: out.append(tok.upper())
    tok=""
print("\n".join(sorted(set(out))))' $M/capabilities.txt > /tmp/listed
echo "readable but not listed:"; comm -23 /tmp/readable /tmp/listed
echo "listed but not readable:";  comm -13 /tmp/readable /tmp/listed
```

- **Readable but not listed** is common. On the HP: 05 06 14 AA AC AE B6 DA E9. Treat these as real controls whose values must come from MCCS or the vendor.
- **Listed but not readable** means one of two things. It may be a write-only or action code (for example 04, factory reset). Or it is a vendor code that needs a sub-code selected before it can be read. On the HP, the nested codes DC, E1, E8, EB, F5 and F8 all answered `unsupported` to a plain read. **Don't try to make them answer by writing**; that is phase 6.

## Classify every readable code

For each `ok` line, fill in its catalog row:

| Field | How to read it |
| --- | --- |
| type | `type=0` is a set parameter, `type=1` a momentary control |
| current | `cur`, decimal and hex |
| maximum | `max`: for a continuous control, its range. For a non-continuous code it is meaningless, sometimes just the current value (the HP's 0x60 reads max=0x13) |
| meaning | the MCCS name, or the vendor's for 0xE0–0xFF |
| values | from the caps list, MCCS or the user guide |

Look out for these quirks, all of which were seen on the HP:
- A range that isn't 0–100. The RGB gains ran 0–255 on the HP.
- A 24-bit value with its top byte dropped. 0xAC read 0xB1FC where the true value is 0x01B1FC; compare it with `glim timing`.
- A code that is only a mirror of something else. The HP's 0x62 volume follows the USB audio level ([phase 5](05-beyond-ddc.md)).
- Read-only information worth recording: firmware (0xC9), MCCS version (0xDF), usage hours (0xC0), display technology (0xB6), controller vendor (0xC8).

## Mark the hazards now

Before phase 4, flag every code in the catalog that appears in the ⚠️ tier of [04-write-tests.md](04-write-tests.md#risk-tiers): input, power, factory reset, OSD lock, save, and every vendor code. Note how to recover from each. Search the user guide for words like "reset", "DDC/CI", "lock" and "power button".
