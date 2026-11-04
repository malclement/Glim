#!/usr/bin/env bash
# Notarizes the app and its disk image with Apple and staples both tickets:
#
#   scripts/notarize.sh dist/Glim.app dist/Glim-0.1.0.dmg
#
# 1. zip the signed app and submit it, 2. staple the app, 3. rebuild the DMG
# from the stapled app (make-dmg.sh signs it), 4. submit the DMG, 5. staple it.
# With both stapled, Gatekeeper can check the download and the installed app
# without a network connection.
#
# The app must already be signed by `make app` with SIGN_IDENTITY set to a
# Developer ID Application identity. Credentials, first match wins:
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID   App Store Connect API key (.p8)
#   NOTARY_PROFILE                                     a `notarytool store-credentials` profile
# NOTARY_TIMEOUT bounds each wait for Apple (default 45m).
set -euo pipefail

log() { printf 'notarize: %s\n' "$*"; }
die() {
    printf 'notarize: error: %s\n' "$*" >&2
    exit 1
}

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <app> <dmg>" >&2
    exit 64
fi
app=$1
dmg=$2
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
identity=${SIGN_IDENTITY:--}
timeout=${NOTARY_TIMEOUT:-45m}

[[ $identity != - ]] ||
    die 'refusing to notarize an ad-hoc build: set SIGN_IDENTITY to your "Developer ID Application: …" identity and rebuild with make dmg'
[[ -f $app/Contents/Info.plist ]] || die "no app bundle at $app (run make dmg first)"

# The key ID and issuer go to notarytool only; nothing here prints them.
if [[ -n ${NOTARY_KEY_PATH:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER_ID:-} ]]; then
    [[ -n ${NOTARY_KEY_PATH:-} && -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER_ID:-} ]] ||
        die "an App Store Connect API key needs all three of NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID"
    [[ -f $NOTARY_KEY_PATH && -r $NOTARY_KEY_PATH ]] || die "NOTARY_KEY_PATH is not a readable file: $NOTARY_KEY_PATH"
    auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    log "authenticating with an App Store Connect API key"
elif [[ -n ${NOTARY_PROFILE:-} ]]; then
    auth=(--keychain-profile "$NOTARY_PROFILE")
    log "authenticating with keychain profile $NOTARY_PROFILE"
else
    die "no notary credentials: set NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID, or NOTARY_PROFILE (docs/release.md)"
fi

# Apple rejects all of these too, but only after an upload and a wait.
details=$(codesign --display --verbose=2 "$app" 2>&1) || die "$app is not signed"
grep -q '^Authority=Developer ID Application: ' <<<"$details" ||
    die "$app is not signed with a Developer ID Application certificate"
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$details" ||
    die "$app is not signed with the hardened runtime (codesign --options runtime)"
grep -q '^Timestamp=' <<<"$details" || die "$app has no secure timestamp (codesign --timestamp)"
codesign --verify --deep --strict "$app" || die "$app does not pass codesign --verify"

tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp%/}/glim-notarize.XXXXXX")
trap 'rm -rf "$work"' EXIT

# plist_value <key> <file>: the value, or nothing. PlistBuddy reports a missing
# or empty file on stdout, so its output only counts when it succeeds.
plist_value() {
    local value
    if value=$(/usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null); then
        printf '%s' "$value"
    fi
}

# submit <file>: uploads, waits, and stops with Apple's log unless Accepted.
submit() {
    local file=$1 result=$work/result.plist id status
    log "submitting $(basename "$file"), waiting up to $timeout"
    # Its exit status is not relied on: the status it reports decides.
    xcrun notarytool submit "$file" "${auth[@]}" --wait --timeout "$timeout" \
        --output-format plist >"$result" || true
    id=$(plist_value id "$result")
    status=$(plist_value status "$result")
    [[ $id =~ ^[0-9A-Fa-f-]{36}$ ]] ||
        die "notarytool returned no submission id for $(basename "$file") (its error is above)"
    log "submission $id: ${status:-no status}"
    case $status in
        Accepted) ;;
        "In Progress")
            die "Apple is still processing submission $id after $timeout; follow it with: xcrun notarytool wait $id <credentials>"
            ;;
        *)
            log "Apple's log for submission $id:"
            xcrun notarytool log "$id" "${auth[@]}" || log "(the log could not be fetched)"
            die "notarization of $(basename "$file") ended with status: ${status:-unknown}"
            ;;
    esac
}

# staple <path>: a fresh ticket can take a moment to be served, so retry.
staple() {
    local target=$1 try
    for try in 1 2 3; do
        if xcrun stapler staple "$target" && xcrun stapler validate "$target"; then
            return 0
        fi
        if ((try < 3)); then
            log "stapling $(basename "$target") failed (attempt $try of 3), retrying"
            sleep $((try * 20))
        fi
    done
    die "could not staple a ticket to $target"
}

zip=$work/$(basename "$app" .app).zip
log "zipping $(basename "$app")"
ditto -c -k --keepParent "$app" "$zip"
submit "$zip"
staple "$app"

log "rebuilding $(basename "$dmg") from the stapled app"
"$scripts_dir/make-dmg.sh" "$app" "$dmg"
submit "$dmg"
staple "$dmg"

log "notarized and stapled $app and $dmg"
