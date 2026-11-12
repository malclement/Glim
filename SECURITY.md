# Security policy

## Reporting a vulnerability

Please report security problems privately, through GitHub's [private vulnerability reporting](https://github.com/malclement/Glim/security/advisories/new). Don't open a public issue for them.

Say what you found, how to reproduce it, and which version of Glim you ran (**Settings › About**, or the commit for a source build). You should hear back within a week. Glim is maintained by one person in their spare time, so a fix can take longer; you'll be told what is planned.

## Supported versions

Only the latest release gets fixes. Builds from `main` are fixed on `main`.

## What counts

Glim runs outside the App Sandbox, with the Hardened Runtime and no entitlements: it has to, to reach DDC/CI through IOAVService (see `Support/Glim.entitlements`). It makes no network connections. Reports that fit that picture are especially welcome:

- anything that makes Glim send a DDC/CI write it shouldn't: an input, power, factory-reset or vendor (0xE0–0xFF) code, or any write the user didn't ask for. A wrong write can blank a monitor, turn its DDC/CI off or reset it, so these are treated as security bugs;
- a crafted capabilities string, EDID or DDC/CI reply that crashes Glim or corrupts its state;
- stored preferences that, once tampered with, make Glim misbehave beyond falling back to defaults;
- serial numbers, display UUIDs or audio device UIDs that reach **Copy Diagnostics** or the logs, which are meant to leave them out;
- problems in the release workflow or the published DMGs.

Glim relies on a private macOS interface for DDC/CI. A macOS update that breaks it is a bug, not a vulnerability: open an ordinary issue.
