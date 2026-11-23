#!/bin/bash
# Installs the built Mecena Motion bundle into Resolve's OFX folder. Resolve must be closed.
set -euo pipefail
ZIP="$(ls -t "$(dirname "$0")"/../dist/MecenaMotion-*-arm64.zip | head -1)"
DEST="/Library/OFX/Plugins/MecenaMotion.ofx.bundle"
if pgrep -x Resolve >/dev/null; then echo "Chiudi DaVinci Resolve prima di installare Mecena Motion." >&2; exit 1; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
codesign --verify --deep --strict "$TMP/MecenaMotion.ofx.bundle"
rm -rf "$DEST"
ditto "$TMP/MecenaMotion.ofx.bundle" "$DEST"
echo "Installato $(basename "$ZIP"). Riavvia DaVinci Resolve."
