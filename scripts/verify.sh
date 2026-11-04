#!/usr/bin/env bash
# Reports whether a build is fit to distribute:
#
#   scripts/verify.sh [--strict] dist/Glim.app [dist/Glim-0.1.0.dmg]
#
# Default (lenient): prints the signature, hardened runtime, Gatekeeper and
# staple status of the app and the DMG. An ad-hoc build has no Developer ID, no
# notarization ticket and is rejected by Gatekeeper; that is reported as "warn"
# and is not an error. A signature that does not verify, or an executable that
# is not arm64, is an error in both modes.
#
# --strict: the release gate. Fails unless the app and the DMG are signed with
# a Developer ID Application certificate, the app has the hardened runtime,
# Gatekeeper accepts both, both carry a stapled ticket, and the DMG holds this
# same build of the app.
set -euo pipefail

strict=0
if [[ ${1:-} == --strict ]]; then
    strict=1
    shift
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 [--strict] <app> [<dmg>]" >&2
    exit 64
fi
app=$1
dmg=${2:-}

failures=0
warnings=0
ok() { printf '  ok    %s\n' "$*"; }
bad() {
    printf '  FAIL  %s\n' "$*"
    failures=$((failures + 1))
}
# What a release needs and an ad-hoc build is expected to lack.
release_only() {
    if ((strict)); then
        bad "$@"
    else
        printf '  warn  %s\n' "$*"
        warnings=$((warnings + 1))
    fi
}
# Indents a command's output under the check it explains.
indent() { sed 's/^/          /'; }

# check_signature <label> <path>: authority, hardened runtime and timestamp.
check_signature() {
    local label=$1 target=$2 details authority
    details=$(codesign --display --verbose=2 "$target" 2>&1) || true
    authority=$(sed -n '/^Authority=/{s///p;q;}' <<<"$details")  # the leaf certificate
    if [[ $authority == "Developer ID Application: "* ]]; then
        ok "$label signed by $authority"
    elif grep -q '^Signature=adhoc' <<<"$details"; then
        release_only "$label has an ad-hoc signature, not a Developer ID"
    else
        release_only "$label is not signed with a Developer ID Application certificate${authority:+ ($authority)}"
    fi
    if grep -q '^Timestamp=' <<<"$details"; then
        ok "$label signature has a secure timestamp"
    else
        release_only "$label signature has no secure timestamp"
    fi
}

check_staple() {
    local label=$1 target=$2 out
    if out=$(xcrun stapler validate "$target" 2>&1); then
        ok "$label has a stapled notarization ticket"
    else
        release_only "$label has no valid stapled notarization ticket"
        indent <<<"$out" | tail -n 2
    fi
}

echo "== app: $app"
if [[ ! -f $app/Contents/Info.plist ]]; then
    bad "no app bundle at $app (run make app)"
else
    if out=$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1); then
        ok "signature verifies (codesign --verify --deep --strict)"
    else
        bad "signature does not verify"
        indent <<<"$out"
    fi
    check_signature app "$app"
    # Matched on captured output: piping codesign into grep -q under pipefail
    # fails whenever grep exits first and codesign dies of SIGPIPE.
    details=$(codesign --display --verbose=2 "$app" 2>&1) || true
    if grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details"; then
        ok "hardened runtime enabled"
    else
        release_only "hardened runtime not enabled (codesign --options runtime)"
    fi
    executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
    archs=$(lipo -archs "$app/Contents/MacOS/$executable" 2>/dev/null || echo unreadable)
    if [[ $archs == arm64 ]]; then
        ok "executable is arm64"
    else
        bad "executable must be arm64 only, found: $archs"
    fi
    if out=$(spctl --assess --type execute --verbose=4 "$app" 2>&1); then
        ok "Gatekeeper accepts the app ($(sed -n 's/^source=//p' <<<"$out"))"
    else
        release_only "Gatekeeper rejects the app"
        indent <<<"$out"
    fi
    check_staple app "$app"
fi

if [[ -n $dmg ]]; then
    echo "== dmg: $dmg"
    if [[ ! -f $dmg ]]; then
        release_only "no disk image at $dmg (run make dmg)"
    else
        out=$(codesign --verify --strict --verbose=2 "$dmg" 2>&1) && status=0 || status=$?
        if ((status == 0)); then
            ok "signature verifies"
            check_signature dmg "$dmg"
        elif grep -q 'not signed at all' <<<"$out"; then
            release_only "disk image is not signed (only a Developer ID build signs it)"
        else
            bad "disk image signature does not verify"
            indent <<<"$out"
        fi
        if out=$(spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" 2>&1); then
            ok "Gatekeeper accepts the disk image ($(sed -n 's/^source=//p' <<<"$out"))"
        else
            release_only "Gatekeeper rejects the disk image"
            indent <<<"$out"
        fi
        check_staple dmg "$dmg"

        # The DMG is what people download: check the copy of the app inside it.
        tmp=${TMPDIR:-/tmp}
        mount_point=$(mktemp -d "${tmp%/}/glim-verify.XXXXXX")
        trap 'hdiutil detach -quiet -force "$mount_point" 2>/dev/null || true; rmdir "$mount_point" 2>/dev/null || true' EXIT
        if hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount_point" "$dmg"; then
            inner=$mount_point/$(basename "$app")
            if [[ ! -d $inner ]]; then
                bad "the disk image has no $(basename "$app")"
            elif ! out=$(codesign --verify --deep --strict "$inner" 2>&1); then
                bad "the app inside the disk image does not verify"
                indent <<<"$out"
            else
                ok "the app inside the disk image verifies"
                cdhash() { codesign --display --verbose=3 "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
                inner_hash=$(cdhash "$inner")
                if [[ -n $inner_hash && $inner_hash == "$(cdhash "$app")" ]]; then
                    ok "it is the same build as $app"
                else
                    release_only "it is a different build from $app (rebuild the DMG)"
                fi
                check_staple "app inside the disk image" "$inner"
            fi
            hdiutil detach -quiet "$mount_point" || hdiutil detach -quiet -force "$mount_point"
        else
            bad "the disk image does not mount"
        fi
    fi
fi

echo
if ((failures)); then
    echo "verify: $failures check(s) failed"
    exit 1
elif ((strict)); then
    echo "verify: releasable: Developer ID signed, hardened, notarized and stapled"
elif ((warnings)); then
    echo "verify: usable locally; $warnings check(s) a release needs did not pass (expected for an ad-hoc build)"
else
    echo "verify: every check passed"
fi
