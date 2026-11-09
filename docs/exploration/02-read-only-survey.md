# 2. Read-only survey

Everything in this phase is a read. It is safe on any monitor and takes about ten minutes, most of it the full scan.

```sh
M=data/<vendor>-<model>     # for example data/dell-u2723qe
mkdir -p $M
```

## Capabilities string

```sh
./glim caps > $M/capabilities.txt
```

This is the monitor's self-description, read in 32-byte fragments: `prot`, `type`, `model`, `cmds` (the op-codes it accepts) and `vcp` (the codes it claims, with allowed values in parentheses). Expect 2–4 seconds.

- **Shifted reads are normal.** About one read in seven came back shifted on the HP, and `glim` rejects and retries them. If `caps` prints `no capabilities reply`, run it again with `-v` to see the frames.
- **Treat the string as a hint, not the truth.** On the HP it listed six codes that refuse a plain read, and left out nine that answer one. Phase 3 reconciles the two lists.

## Full scan: the baseline

```sh
./glim scan --all > $M/scan-all.txt     # about 25 s: a Get of all 256 codes
```

Each line is one of three things:

| Result | Meaning |
| --- | --- |
| `0xNN ok type=T cur=C max=M` | the monitor answers this code |
| `0xNN unsupported` | it answered, with result code 01: it does not support the code |
| `0xNN no-reply` | no valid reply after 4 attempts |

**When there are no `no-reply` lines, the scan is definitive.** The set of plainly readable codes is then complete; on the HP it was 49 ok and 207 unsupported. Any `no-reply` line means the link was unreliable: run the scan again before trusting it.

This file is the **baseline** that every write test diffs against. Save a compact form for diffing:

```sh
grep ' ok ' $M/scan-all.txt | awk '{print $1, $4}' > $M/baseline.txt
```

## Timing report

```sh
./glim timing > $M/timing.txt
```

This gives the horizontal and vertical frequencies and the sync polarity the monitor measures. Compare it with the mode macOS reports (`displayprobe`). It also tells you whether the monitor answers op-code 07 at all, and some don't.

## Frames for the test fixtures

Raw frames are what the protocol tests are written against (`Tests/GlimCoreTests/Fixtures`). Capture a few representative exchanges:

```sh
{
  for c in 10 12 60 62 8D; do echo "## get $c"; ./glim -v get $c 2>&1; done
  echo "## get <an unsupported code from the scan>"; ./glim -v get E1 2>&1
  echo "## timing"; ./glim -v timing 2>&1
  echo "## caps";   ./glim -v caps 2>&1
} > $M/frames.txt
```

`->` lines are the frames written; the leading `51` is the I2C data address, not part of the frame. `<-` lines are the start of each 40-byte read. Keep the shifted reads (lines that don't start with `6E`): they are what the parser must reject.

## Check the files before going on

- `capabilities.txt` starts with `(` and contains `vcp(`.
- `scan-all.txt` has 256 lines and no `no-reply`.
- Nothing in the folder contains the serial number. The scan doesn't read it, but check anything you add by hand.
