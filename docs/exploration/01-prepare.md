# 1. Prepare

## What you need

- **A Mac with Apple silicon.** The tools reach DDC/CI through the IOAVService interface, which Intel Macs don't have.
- **The Xcode Command Line Tools** (`xcode-select --install`). Xcode itself is not needed.
- **A direct video connection.** USB-C (DisplayPort alt mode), a DisplayPort cable, or a Thunderbolt dock that tunnels DisplayPort.
  - **DisplayLink docks and adapters carry no DDC/CI.** They are virtual displays over USB.
  - KVM switches and MST hubs often drop it too.
  - ⚠️ Other DDC/CI tools' users report that the built-in HDMI port of some Apple silicon Macs, notably M1 models, carries no DDC/CI. Prefer USB-C if the monitor has it.
- **DDC/CI turned on in the monitor's own menu.** It usually is by default. Note where the switch lives (HP: Management › DDC/CI); you will need it if the monitor stops answering.
- **The monitor's user guide and service manual**, if the vendor publishes them. They name the controls and often list the factory defaults.

## Build the tools

From the repository root:

```sh
make glim     # ./glim, the DDC/CI research CLI (tools/glim-cli/glim.c)
make probes   # the read-only macOS probes in tools/macos-probe
```

| Tool | What it does | Writes anything? |
| --- | --- | --- |
| `./glim` | DDC/CI: capabilities, get, set, scan, timing, raw frames | `set`, `save` and `raw` do |
| `tools/macos-probe/displayprobe` | macOS's view of each display: identity, modes, gamma, colour profile, HDR, software brightness | no |
| `tools/macos-probe/edidprobe` | decodes the EDID the Mac read at connection | no |
| `tools/macos-probe/audioprobe "<name>"` | CoreAudio devices and which volume and mute controls are settable | no |
| `tools/macos-probe/usbdescprobe <vendor-id>` | USB descriptors: audio feature units, webcam controls, HID | no |
| `tools/macos-probe/hidprobe <vendor-id>` | HID report descriptors: buttons, LEDs, vendor channels | no |
| `tools/macos-probe/camprobe` | webcam formats as AVFoundation sees them | no |
| `tools/macos-probe/hpvolume` | reads or sets the **HP E27m G4's** USB audio level. Its device name is hard-wired; edit line 57 for another monitor | yes, the audio level |

`./glim help` lists every command. The options go before the command: `-d N` picks external display N, `-v` hex-dumps every frame, `--force` allows the hazardous writes, and `--no-verify` skips the read-back after `set`.

## Before you start

1. **Quit every other DDC/CI client**, including Glim itself (rule 6 in the [README](README.md)):
   ```sh
   pgrep -l -i -E 'glim|monitorcontrol|betterdisplay|lunar|ddc'
   ```
2. **Connect only the monitor under test.** `glim` numbers external displays in enumeration order, not by identity, so with two connected `-d 1` may not be the one you think. Glim the app matches by EDID; the CLI does not.
3. **Check that DDC/CI answers:**
   ```sh
   ./glim list          # expect: [1] external DCPAVServiceProxy
   ./glim get 10        # brightness; expect a line with type=, cur= and max=
   ```
   If `get 10` prints `no-reply`:
   - Check the DDC/CI switch in the monitor's menu.
   - Try another cable or port, and avoid docks.
   - Wake the monitor; a sleeping monitor doesn't answer.

## Identify the monitor

You need the EDID manufacturer code (three letters), the product code, and the monitor's own name. You do **not** need the serial number; don't copy it anywhere.

```sh
tools/macos-probe/edidprobe | sed -n '1,20p'          # manufacturer, product code, name, input type
tools/macos-probe/displayprobe --external --no-modes  # vendor/model as macOS reports them, current mode
system_profiler SPDisplaysDataType                    # resolution, refresh, connection
```

Write down:
- the manufacturer and product, for example `DEL` and `0xA1B2`, or the HP's `HPN` and `0x3753`;
- the model name, the firmware version if the OSD shows one, and how the monitor is connected;
- the macOS version and the Mac model.

These go at the top of the catalog.

Also find the monitor's **USB vendor ID**, for phase 5. Look for a hub or audio device with the monitor's name:

```sh
system_profiler SPUSBHostDataType | grep -B2 -A8 -i '<model name or brand>'
```
