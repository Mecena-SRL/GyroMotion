#!/bin/bash
# Rimuove Mecena Motion da /Library/OFX/Plugins e la ricevuta dell'installer.
echo "Rimozione di Mecena Motion (serve la password di amministratore)."
sudo rm -rf "/Library/OFX/Plugins/MecenaMotion.ofx.bundle"
sudo pkgutil --forget it.mecena.motion.pkg >/dev/null 2>&1
echo "Fatto. Riavvia DaVinci Resolve."
