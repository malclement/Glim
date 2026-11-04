#!/usr/bin/env bash
# Builds the compressed, drag-to-install disk image for the app:
#
#   scripts/make-dmg.sh dist/Glim.app dist/Glim-0.1.0.dmg
#
# The image holds the app and an Applications symlink over a background with an
# arrow. dmgbuild writes the window layout straight into the image's .DS_Store,
# so nothing drives Finder or AppleScript and it runs headless, on CI too.
#
# dmgbuild and its two dependencies are installed into a throwaway virtualenv
# from exact versions *and* sha256 hashes, because the release job runs this
# while the Developer ID key is unlocked. uvx and pipx run were not used: they
# take a version pin but do not check hashes.
#
# Signs the image when SIGN_IDENTITY is set to anything but "-" (ad-hoc).
# Rerunnable: the output is replaced atomically, staging is always removed.
set -euo pipefail

readonly volume_name=Glim
# dmgbuild 1.6.7, ds-store 1.3.3, mac-alias 2.2.3: all MIT, pure Python, from
# PyPI. To upgrade, take each new py3-none-any wheel's sha256 from
# https://pypi.org/pypi/<name>/json.
readonly requirements='dmgbuild==1.6.7 --hash=sha256:37ee5771c377beb3203d9164aae8046ffed8531c06edf9227f5788b3c599b1bf
ds-store==1.3.3 --hash=sha256:b92a371efbf1b4ccce2a04d1ed13fceacc4736c81ba09cf5aefb74c088160a35
mac-alias==2.2.3 --hash=sha256:7362b521d2132ef92f606a37abfed5fcd849ceb2f28b6f9743e014b02af92f0d'

log() { printf 'make-dmg: %s\n' "$*"; }
die() {
    printf 'make-dmg: error: %s\n' "$*" >&2
    exit 1
}

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <app> <dmg>" >&2
    exit 64
fi
[[ -f $1/Contents/Info.plist ]] || die "not an app bundle: $1"
[[ $2 == *.dmg ]] || die "the output must end in .dmg: $2"

scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
app_name=$(basename "$app")
mkdir -p "$(dirname "$2")"
out_dir=$(cd "$(dirname "$2")" && pwd)
dmg_name=$(basename "$2")
identity=${SIGN_IDENTITY:--}

# The app's icon doubles as the volume icon.
volume_icon=""
icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist" 2>/dev/null) || icon_name=""
if [[ -n $icon_name ]]; then
    volume_icon="$app/Contents/Resources/${icon_name%.icns}.icns"
    [[ -f $volume_icon ]] || die "Info.plist names icon $icon_name, but $volume_icon is missing"
fi

# Everything, including dmgbuild's own scratch image, goes in one directory next
# to the output, so the final move is a rename on the same volume.
stage=$(mktemp -d "$out_dir/.make-dmg.XXXXXX")
mount_point=$stage/mnt
mounted=0
cleanup() {
    if ((mounted)); then hdiutil detach -quiet -force "$mount_point" || true; fi
    rm -rf "$stage"
}
trap cleanup EXIT

# Detaching can also hit "Resource busy" for a moment after a mount.
detach() {
    local try
    for try in 1 2 3 4; do
        if hdiutil detach -quiet "$1"; then return 0; fi
        sleep "$try"
    done
    hdiutil detach -quiet -force "$1"
}

log "installing dmgbuild into a throwaway virtualenv (hash-checked)"
printf '%s\n' "$requirements" >"$stage/requirements.txt"
if command -v uv >/dev/null 2>&1; then
    uv venv --no-config --quiet --python '>=3.10' "$stage/venv"
    uv pip install --no-config --quiet --python "$stage/venv/bin/python" \
        --require-hashes --no-deps --only-binary :all: -r "$stage/requirements.txt"
else
    command -v python3 >/dev/null 2>&1 || die "dmgbuild needs python3 (3.10 or later) or uv"
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' ||
        die "dmgbuild needs Python 3.10 or later, found $(python3 --version 2>&1)"
    python3 -m venv "$stage/venv"
    "$stage/venv/bin/python" -m pip install --quiet --disable-pip-version-check --no-input \
        --require-hashes --no-deps --only-binary :all: -r "$stage/requirements.txt"
fi

log "drawing the window background"
swift "$scripts_dir/make-icon.swift" --dmg-background "$stage/background"

# dmgbuild executes this file. The window shows 640 x 400 pt of content; its
# bounds include the title bar. The icon centres line up with the arrow that
# scripts/make-icon.swift draws, so change both together.
cat >"$stage/settings.py" <<'EOF'
import os.path

application = defines["app"]
files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"] or None
background = defines["background"]

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

window_rect = ((200, 140), (640, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(application): (160, 196),
    "Applications": (480, 196),
}
EOF

# hdiutil fails now and then on CI runners with "Resource busy" while macOS
# scans the fresh image; the accepted workaround is to retry.
image=$stage/$dmg_name
attempt=1
until "$stage/venv/bin/dmgbuild" --settings "$stage/settings.py" \
    -D app="$app" -D icon="$volume_icon" -D background="$stage/background/background.png" \
    --detach-retries 10 "$volume_name" "$image"; do
    ((attempt < 3)) || die "dmgbuild failed $attempt times"
    log "dmgbuild failed (attempt $attempt of 3), retrying"
    rm -f "$image"
    sleep $((attempt * 10))
    attempt=$((attempt + 1))
done

if [[ $identity != - ]]; then
    log "signing the disk image"
    codesign --force --sign "$identity" --timestamp "$image"
    codesign --verify --strict "$image" || die "the disk image signature does not verify"
fi

# dmgbuild does not check that the app was copied in, so open the result and
# look: the bundle must be intact and its signature still valid.
log "checking the disk image"
hdiutil verify -quiet "$image" || die "hdiutil verify failed for $image"
mkdir "$mount_point"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -noverify -mountpoint "$mount_point" "$image"
mounted=1
[[ -d $mount_point/$app_name ]] || die "$app_name is missing from the disk image"
[[ -L $mount_point/Applications && $(readlink "$mount_point/Applications") == /Applications ]] ||
    die "the Applications symlink is missing from the disk image"
[[ -f $mount_point/.DS_Store && -f $mount_point/.background.tiff ]] ||
    die "the window layout (.DS_Store, .background.tiff) is missing from the disk image"
codesign --verify --deep --strict "$mount_point/$app_name" ||
    die "$app_name inside the disk image does not pass codesign --verify"
detach "$mount_point"
mounted=0

mv -f "$image" "$out_dir/$dmg_name"
log "built $out_dir/$dmg_name ($(du -h "$out_dir/$dmg_name" | cut -f1 | tr -d ' '), identity: $identity)"
