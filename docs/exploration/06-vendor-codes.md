# 6. Vendor codes (0xE0–0xFF)

MCCS leaves 0xE0–0xFF to manufacturers, and many put their most interesting settings there. The HP's include auto-sleep, power mode, USB-C lane allocation, audio presets and OSD layout. They are also where the worst hazards are: one HP value turns DDC/CI off, another performs a master reset. Do this phase only with the owner's agreement and someone at the monitor.

## Where the truth comes from

Not from experiments. Blind writes are how monitors get locked out (rule 3 in the [README](README.md)). The reliable sources, best first:

1. **The vendor's own control software.** Its tables map feature names to codes, sub-codes and values, and its code shows the wire protocol. For the HP that was HP Display Center (Windows, .NET). It was taken apart, never run: its enums gave the names, and its VCP handler gave the sub-code read and write sequence.
   - **Those tables are the vendor's work.** Use them to understand the protocol and to write your own descriptions in the catalog, but don't commit them to the repository.
2. **Public reverse-engineering**: ddcutil and ddccontrol issues, MonitorControl and Lunar issues, and blog posts on the model or its siblings. Note the model each finding was made on.
3. **The capabilities string**: which vendor codes, and which sub-codes and values, this firmware claims.
4. **A plain read of each vendor code** from the full scan. Flat codes answer it; sub-coded ones (nested in the caps) usually reply `unsupported`.

## Flat codes versus sub-coded codes

- **Flat codes** answer a normal Get and Set. If the scan reads them and the vendor material documents them, treat them like the caution tier of [phase 4](04-write-tests.md#risk-tiers), one at a time with a full-scan diff.
- **Sub-coded codes** (nested in the caps, for example `E1(04(...) 0F(...))`) multiplex many settings behind one code. On HP firmware, **even a read starts with a write**: a Set selects the sub-code, then a Get returns its value. A mistake in that protocol therefore writes something.
- `glim` implements HP's version as `hp-get`, `hp-set` and `hp-string`, all behind `--force`; `docs/controls.md` § 6 describes the wire format.
- **Other vendors' sub-code schemes are unknown.** Don't assume HP's.

## A safe order for a first session

Go from the least to the most consequential, and stop at the first surprise:

1. **A pure read whose answer you can check.** For example a model-name or firmware string, compared with the OSD's Information page. HP: `glim --force hp-string F5 0D`.
2. **A harmless setting**, read back. HP: auto-sleep, `hp-get E1 0F`.
3. **A round trip on that setting**: write the opposite value, check the OSD, then restore it.
4. Only then, anything that changes the link, power or USB: lane allocation, power mode, DisplayPort version. Do it with the cable within reach.

## Never, even with `--force`

- Any value documented as turning DDC/CI off.
- Factory or master resets.
- Button locks.
- Theft-deterrence and PIN codes. On the HP, the theft PIN is **readable over DDC/CI** (CVE-2023-5449); record that it exists, never its value.

## Recording

- Mark vendor findings 📄 until they are verified on the unit, then ✅ with the exact wire sequence used.
- Record every sub-code the caps list that no source explains under ❓, with its listed values. The HP has several.
