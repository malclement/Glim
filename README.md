# Glim

Glim controls an external monitor's hardware from a Mac. It talks DDC/CI to the monitor, so it can set brightness, contrast, color, input, menu settings and more on Apple Silicon. It started as a full investigation of an **HP E27m G4** and catalogs every control that monitor exposes.

## Build

You need the Xcode Command Line Tools. Xcode itself isn't required.

```sh
make                      # builds ./glim
make -C tools/macos-probe # optional: read-only macOS / USB / audio / webcam probes
```

## Use

```sh
./glim caps                 # what the monitor says it supports
./glim scan                 # read every VCP code
./glim get brightness       # or a hex code: ./glim get 10
./glim set brightness 60    # writes, then reads back
./glim set color-preset 5   # 6500 K (factory)
./glim timing               # sync frequencies and polarity
./glim -v get 10            # hex-dump the DDC frames
./glim help
```

`glim` refuses writes that can blank the screen, drop the monitor off DDC, or wipe settings (`04 60 CA D6 DC E0–FF`, and the `hp-*` commands) unless you pass `--force`.

## What's in here

| Path | Contents |
| --- | --- |
| [docs/controls.md](docs/controls.md) | **Every DDC/CI control on the HP E27m G4**: what it does, its values, its current value, and whether it was verified on hardware or only documented. Also covers HP's vendor sub-code protocol and the hazards. |
| [docs/macos-usb-webcam.md](docs/macos-usb-webcam.md) | Everything outside DDC: display modes, EDID, gamma, the USB-C link and power, USB Audio (where the speaker volume really lives), the HID front-panel keys, and the webcam |
| [docs/ddc-ci-protocol.md](docs/ddc-ci-protocol.md) | How DDC/CI works on Apple Silicon: the transport, framing, commands and timing quirks |
| [docs/open-items.md](docs/open-items.md) | What's still untested: risky writes, the HP vendor protocol, and checks that need someone at the monitor |
| [data/](data) | Raw evidence: the capabilities string, the full scan, the write-test log, and HP Display Center's feature and value tables |
| [src/glim.c](src/glim.c) | The CLI |
| [tools/macos-probe/](tools/macos-probe) | Read-only probes for display, EDID, audio, camera, USB and HID, plus `hpvolume` (USB Audio level) |

## Caveats

- DDC on Apple Silicon goes through the **private** `IOAVService` API, the same one MonitorControl, BetterDisplay and m1ddc use. A macOS update can break it.
- Tested on one machine: an M4 MacBook Air on macOS 26.5, with an HP E27m G4 (firmware 1.0) over USB-C. Other monitors will work for the standard codes. The HP sections are model-specific.
