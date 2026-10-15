#!/bin/bash
# Installs the latest GitHub release of MyGitApp into /Applications.
# Downloading with gh (not a browser) means macOS doesn't quarantine the unsigned app.
set -euo pipefail

REPO="slaynn/mygitapp"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName)"
INSTALLED="$(defaults read /Applications/MyGitApp.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || true)"
if [[ "v$INSTALLED" == "$TAG" ]]; then
  echo "MyGitApp $INSTALLED est déjà à jour."
  exit 0
fi

echo "Téléchargement de MyGitApp $TAG…"
gh release download "$TAG" --repo "$REPO" --pattern "MyGitApp-*.zip" --dir "$TMP"
ditto -x -k "$TMP"/MyGitApp-*.zip "$TMP"

pkill -x MyGitApp 2>/dev/null && sleep 1 || true
rm -rf /Applications/MyGitApp.app
mv "$TMP/MyGitApp.app" /Applications/
xattr -dr com.apple.quarantine /Applications/MyGitApp.app 2>/dev/null || true

echo "MyGitApp ${TAG#v} installée${INSTALLED:+ (avant : $INSTALLED)}."
open /Applications/MyGitApp.app
