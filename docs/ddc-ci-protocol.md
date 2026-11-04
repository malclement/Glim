# How DDC/CI works on this Mac

This note covers what happens on the wire when `glim` talks to the monitor. Everything here was observed on an Apple M4 MacBook Air (macOS 26.5) connected to an HP E27m G4 over USB-C, unless it is marked ⚠️.

## The transport

```
glim ──IOAVServiceWriteI2C/ReadI2C──▶ DCP (display coprocessor) ──DP AUX over USB-C──▶ monitor scaler, I2C slave 0x37
```

- **Apple Silicon has no `/dev/i2c`.** The only route to the monitor's I2C bus is the private IOKit API `IOAVService*`, called on the `DCPAVServiceProxy` registry entry whose `Location` is `External`. m1ddc, MonitorControl, BetterDisplay and Lunar all use this same path.
- **The API is private.** Apple can break it in any macOS release, and it has changed before. If `glim list` finds nothing after an update, start looking there.
- **The built-in panel has no DDC.** Its proxy says `Location = Embedded`, and its brightness belongs to macOS (DisplayServices), not to DDC.

## Frame format

Host to monitor, passed as `IOAVServiceWriteI2C(service, 0x37, 0x51, buf, len)`:

```
[0x80 | n] [op] [args…] [checksum]     checksum = 0x6E ^ 0x51 ^ every byte before it
```

Monitor to host, read with `IOAVServiceReadI2C(service, 0x37, 0x51, buf, 40)`:

```
[0x6E] [0x80 | n] [op] [args…] [checksum]     checksum = 0x50 ^ every byte before it
```

✅ Replies from this monitor always pass the checksum.

✅ The timing reply is an exception. Its length byte is a bare `0x06` without the `0x80` bit, so a parser that insists on that bit drops it. A captured exchange:

```
-> 51 81 07 B9
<- 6E 06 4E 02 2B 66 1D 4C 68
```

## Commands the monitor accepts (`cmds(01 02 03 07 0C E3 F3)`)

| Op | Name | Request | Reply | Verified |
| --- | --- | --- | --- | --- |
| `01` | VCP Get | `01 <code>` | `02 <rc> <code> <type> <maxH> <maxL> <curH> <curL>` | ✅ `rc=00` supported, `rc=01` unsupported |
| `02` | VCP Get reply | — | (above) | ✅ |
| `03` | VCP Set | `03 <code> <valH> <valL>` | none | ✅ |
| `07` | Timing request | `07` | `4E <status> <hH> <hL> <vH> <vL>` | ✅ H in 10 Hz units, V in 0.01 Hz units: 111.10 kHz / 75.00 Hz |
| `0C` | Save current settings | `0C` | none | ⚠️ sent but not observable. Settings already persist without it. |
| `F3` / `E3` | Capabilities request / reply | `F3 <offH> <offL>` | `E3 <offH> <offL> <≤32 bytes>` | ✅ Read in fragments until an empty one arrives. See `data/capabilities.txt`. |

- ✅ **Table read (`E2`) is not supported.** It isn't in `cmds`, and the monitor answers with an empty (null) message.
- ✅ **Malformed requests get an error reply.** A VCP Get with an extra byte (for example `01 E1 04`) is answered `02 01 BF …`, an "unsupported" reply carrying the dummy code `BF`.

## Reading reliably

- ✅ **Wait before reading.** The spec asks for at least 40 ms between a request and reading its reply. `glim` waits 50 ms.
- ✅ **Send each write twice, 10 ms apart.** The DCP occasionally drops the first one. m1ddc does the same.
- ✅ **A Get sent right after a Set can read 0.** Wait about 200 ms and read again. `glim set` does this before printing the read-back value.
- ✅ **The full scan is definitive.** `glim scan --all` gets a reply for all 256 codes: 49 `ok`, 207 `unsupported`, 0 `no-reply`. The readable surface in `data/scan-all.txt` is therefore complete. Codes that are write-only (or need sub-addressing) can still exist beyond it, as covered in [controls.md](controls.md).
- ✅ **The capabilities string and the scan disagree.**
  - Answer a Get but are **missing from caps**: `05 06 14 AA AC AE B6 DA E9`.
  - Are **in caps but refuse a plain Get** (`rc=01`): `DC E1 E8 EB F5 F8`. All six use nested syntax in caps.
