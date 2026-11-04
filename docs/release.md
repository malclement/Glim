# Releasing Glim

A `v*` tag runs `.github/workflows/release.yml`, which builds `Glim-<version>.dmg`.

- **With the five signing secrets set**, the workflow signs the app and the DMG with a Developer ID, notarizes and staples both, checks the result with `make verify-strict`, and publishes the release.
- **Without them**, the workflow builds an ad-hoc signed DMG and creates a **draft** release. Its notes explain how to open an unnotarized app.

In both cases the notes carry the DMG's SHA-256. A tag that contains `-`, such as `v0.2.0-beta.1`, is published as a prerelease.

## Cut a release

1. Set `CFBundleShortVersionString` in `Support/Info.plist`, for example `0.2.0`. The tag must be exactly `v` plus this value, so a prerelease tag `v0.2.0-beta.1` needs `0.2.0-beta.1` in the plist. Apple documents the key as digits and dots only, but nothing in this pipeline enforces that.
2. Merge to `main` and wait for CI to pass.
3. Tag and push:

   ```sh
   git tag -a v0.2.0 -m "Glim 0.2.0"
   git push origin v0.2.0
   ```

4. Check the release. A draft stays private until you publish it from the Releases page or run `gh release edit v0.2.0 --draft=false`.

`CFBundleVersion` is the workflow's run number.

**Dry run.** Go to Actions → Release → Run workflow. It builds the same candidate, signed if the secrets exist, and uploads it as an artifact without publishing anything. GitHub can only run a manual workflow whose file is already on the default branch.

## Secrets

Set either all five secrets under Settings → Secrets and variables → Actions, or none of them. If only some are set, the job fails instead of quietly shipping an unsigned build.

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Developer ID Application certificate and private key, as a `.p12` file, base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | The password you chose when you exported the `.p12` |
| `NOTARY_API_KEY_P8` | App Store Connect API private key (`AuthKey_XXXXXXXXXX.p8`), base64-encoded |
| `NOTARY_API_KEY_ID` | That key's ID: 10 characters, also the middle of the file name |
| `NOTARY_API_ISSUER_ID` | Your team's issuer ID (a UUID) |

Both credentials need a paid Apple Developer Program membership.

**Developer ID Application certificate.** Only the team's Account Holder can create one.

1. On a Mac, open Keychain Access and choose Certificate Assistant → Request a Certificate From a Certificate Authority. Save the request to disk.
2. Open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list) and click **+**. Choose **Developer ID Application**, upload the request, and download the `.cer` file.
3. Double-click the `.cer` file to add it to your login keychain.
4. In Keychain Access, go to **My Certificates** and select **Developer ID Application: … (TEAMID)**. Its disclosure triangle should show a private key. Choose File → Export Items, and save a `.p12` with a strong password.
5. Store the secrets:

   ```sh
   base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12
   gh secret set MACOS_CERTIFICATE_PASSWORD
   ```

**App Store Connect API key.**

1. Open [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/api). Under Team Keys, generate a key. The Developer role is commonly reported to be enough for notarization; this has not been verified here.
2. Download the `.p8` file. Apple lets you download it only once.
3. Copy the key ID from the key list and the **Issuer ID** shown above it.
4. Store the secrets:

   ```sh
   base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY_P8
   gh secret set NOTARY_API_KEY_ID
   gh secret set NOTARY_API_ISSUER_ID
   ```

During a run the certificate goes into a temporary keychain whose password is generated in the job. The `.p8` file is written to `$RUNNER_TEMP` with mode 600. A final `if: always()` step deletes both.

## Build locally

```sh
make dmg                                    # ad-hoc: runs on this Mac only
make verify                                 # what a release would still need

security find-identity -v -p codesigning    # your "Developer ID Application: …"
xcrun notarytool store-credentials glim \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>   # once
make dmg       SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
make notarize  SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=glim
make verify-strict
```

`make notarize` also accepts `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` instead of a profile. It needs `SIGN_IDENTITY` again because it rebuilds and re-signs the DMG around the stapled app.

## How it works

- `scripts/make-icon.swift` draws the icon and the DMG background with CoreGraphics. No image files are committed.
- `scripts/make-dmg.sh` uses [dmgbuild](https://github.com/dmgbuild/dmgbuild) (MIT) to write the Finder layout into the image without driving Finder. dmgbuild and its two dependencies are pinned by version and sha256 and installed into a throwaway virtualenv. To upgrade them, update `requirements` in that script with the new versions and their wheel hashes from PyPI.
- `scripts/notarize.sh` submits the zipped app, staples the app, rebuilds and signs the DMG, then submits and staples the DMG.
- `scripts/verify.sh` reports the result. Its default mode tolerates an ad-hoc build. `--strict` is the release gate, and it also checks that the DMG contains the same build as `dist/Glim.app`.

## What has been verified

Verified on macOS 26.5 with the Command Line Tools (Swift 6.1.2):

- The ad-hoc path: `make app`, `make dmg`, and the DMG's contents and window layout (`.DS_Store` decoded).
- `make verify` passes on the ad-hoc build. `make verify-strict` rejects it.
- `notarize.sh` refuses ad-hoc builds and incomplete credentials. Its control flow (submit, staple retry, DMG rebuild, Invalid status, auth error, timeout) was run against mocked `notarytool`, `stapler` and `codesign`.
- Both uv and pip refuse dmgbuild when the hash is wrong.
- Both workflows parse.

**Not verified.** There is no Developer ID on the development machine, so none of the following has run: Developer ID signing, notarization, stapling, Gatekeeper accepting the build, the workflow's keychain import, and either workflow on GitHub's runners. The first run with secrets is the first real test, so do a manual dry run before pushing a tag. Nobody has looked at the DMG window in Finder either. Its background is mid-toned so that Finder's black labels (Light Mode) and white labels (Dark Mode) both stay readable.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `refusing to notarize an ad-hoc build` | Pass `SIGN_IDENTITY` to both `make dmg` and `make notarize`. |
| CI: `holds no valid Developer ID Application identity` | The `.p12` has no private key (export it from My Certificates, not Certificates), or its chain is not trusted. Import Apple's Developer ID G2 intermediate from [apple.com/certificateauthority](https://www.apple.com/certificateauthority/). |
| CI hangs in `codesign`, or fails with `errSecInternalComponent` | The key is not usable without a prompt: the keychain is locked or the partition list is missing. The workflow sets both, so check that step's log. |
| Notarization `Invalid` | The script prints Apple's log. The usual causes are a missing hardened runtime, a missing secure timestamp, or unsigned nested code. |
| `stapler staple` fails right after `Accepted` | The ticket can take a moment to be published. The script retries three times; otherwise run `xcrun stapler staple <path>` again later. |
| `spctl … rejected`, `source=Unnotarized Developer ID` | Signed but not notarized or stapled. Run `make notarize`. |
| CI: `hdiutil: create failed - Resource busy` | A known flake on GitHub's macOS runners. `make-dmg.sh` retries three times; if it still fails, re-run the job. |
| `Tag vX does not match CFBundleShortVersionString` | Fix the plist, then move the tag: `git push --delete origin vX`, retag, and push again. |
| Users see "Glim is damaged" or "can't be opened" | The build is not notarized. Use **Open Anyway** in System Settings → Privacy & Security, or run `xattr -dr com.apple.quarantine /Applications/Glim.app`. |
