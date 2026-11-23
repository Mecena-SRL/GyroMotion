#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds and installs Mecena Motion for Final Cut Pro on this Mac:
#   1. the FxPlug wrapper app (with the effects inside) -> /Applications/Mecena Motion.app
#   2. the Motion Templates that list the effects in Final Cut's Effects browser
#      -> ~/Movies/Motion Templates.localized/Effects.localized/Mecena Motion
# Needs Xcode, Rust, the Apple FxPlug SDK, and Log MetaRaw for Final Cut (its index of the libraries finds the
# original file of each clip). The engine is built first: ../release/build-fxplug.sh
#
#   CODE_SIGN_IDENTITY=<identity or SHA-1> ./install.sh     (default "-": ad hoc)
#
# Final Cut Pro must be restarted afterwards. Uninstall: ./install.sh --uninstall
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ID="${CODE_SIGN_IDENTITY:--}"
APP_DEST="/Applications/Mecena Motion.app"
PLUG_REL="Contents/PlugIns/MecenaMotionPlugin.pluginkit"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TPL_DEST="$HOME/Movies/Motion Templates.localized/Effects.localized/Mecena Motion"
DD="$HERE/build/xc"

forget() {   # unregister a copy of the app so that pkd cannot prefer it over the installed one
    [ -d "$1" ] || return 0
    pluginkit -r "$1/$PLUG_REL" >/dev/null 2>&1 || true
    "$LSR" -u "$1" >/dev/null 2>&1 || true
}

# Replacing the plug-in under a running Final Cut Pro leaves it retrying the old XPC service (it hangs).
if pgrep -x "Final Cut Pro" >/dev/null; then
    echo "Chiudi Final Cut Pro prima di installare o disinstallare Mecena Motion." >&2
    exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
    forget "$APP_DEST"
    rm -rf "$APP_DEST" "$TPL_DEST"
    echo "Mecena Motion rimosso. Riavvia Final Cut Pro."
    exit 0
fi

echo "== Motore (Rust)"
[ -f "$HERE/build/lib/libmecena_fxplug.a" ] || bash "$HERE/../release/build-fxplug.sh"
echo "== Progetto Xcode e build"
python3 "$HERE/make_xcodeproj.py" >/dev/null
xcodebuild -project "$HERE/MecenaMotion.xcodeproj" -scheme MecenaMotion -configuration Release \
    -derivedDataPath "$DD" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$ID" DEVELOPMENT_TEAM= build \
    > "$HERE/build/xcodebuild.log" 2>&1 || { tail -20 "$HERE/build/xcodebuild.log"; exit 1; }
BUILT="$DD/Build/Products/Release/Mecena Motion.app"
codesign --verify --deep --strict "$BUILT"

echo "== Installazione in /Applications"
forget "$BUILT"                       # xcodebuild registers the build copy: it must not win
for old in "$HOME/Applications/Mecena Motion.app" "/Library/Plug-Ins/FxPlug/Mecena Motion.app" \
           "$HOME"/Library/Developer/Xcode/DerivedData/MecenaMotion-*/Build/Products/*/"Mecena Motion.app"; do
    forget "$old"
done
forget "$APP_DEST"
rm -rf "$APP_DEST"
cp -R "$BUILT" "$APP_DEST"
rm -rf "$DD/Build/Products"            # no second copy with the same identifier for pkd to prefer
"$LSR" -f "$APP_DEST"
pluginkit -a "$APP_DEST/$PLUG_REL"
pluginkit -e use -i it.mecena.motion.fcp.Plugin

echo "== Motion Template (elenca l'effetto in Final Cut)"
python3 "$HERE/make_motion_template.py" --install

echo "== Verifica della registrazione"
# pkd handles the removals above asynchronously and can drop the new registration seconds later (same identifier):
# keep checking for 20 s and register again whenever it is gone.
for i in $(seq 1 10); do
    sleep 2
    if ! pluginkit -mA -p FxPlug | grep -q "/Applications/Mecena Motion.app"; then
        pluginkit -a "$APP_DEST/$PLUG_REL"
        pluginkit -e use -i it.mecena.motion.fcp.Plugin
    fi
done
ok=0
for i in $(seq 1 5); do   # pkd can still be dropping the old copy: register again until it holds
    if pluginkit -mAv -p FxPlug | grep -i it.mecena.motion; then ok=1; break; fi
    "$LSR" -f "$APP_DEST"
    pluginkit -a "$APP_DEST/$PLUG_REL"
    pluginkit -e use -i it.mecena.motion.fcp.Plugin
    sleep 3
done
[ "$ok" = 1 ] || { echo "ATTENZIONE: plugin non registrato"; exit 1; }
echo "Fatto. Riavvia Final Cut Pro: Effetti > Mecena Motion."
