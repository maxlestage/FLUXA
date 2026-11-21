#!/usr/bin/env bash
# Choisit la version de Xcode la plus récente installée sur la machine, hors bêta :
# App Store Connect demande un SDK récent (ITMS-90725), et refuse ce qui sort d'un
# Xcode bêta. Affiche les versions présentes et celle retenue.
set -euo pipefail
echo "Versions de Xcode installées :"
ls -d /Applications/Xcode*.app 2>/dev/null | sed 's|^|  |' || true
latest=$(ls -d /Applications/Xcode_*.app 2>/dev/null \
  | grep -viE 'beta|_rc|release_candidate' \
  | sed -E 's|^/Applications/Xcode_([0-9.]+)\.app$|\1 &|' \
  | grep -E '^[0-9]' \
  | sort -V | tail -1 | cut -d' ' -f2)
if [ -n "${latest:-}" ]; then
  sudo xcode-select -s "$latest/Contents/Developer"
fi
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version | sed 's/^/SDK iOS : /'
