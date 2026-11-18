#!/usr/bin/env bash
# Sign the built app, zip it, sign the zip for Sparkle and write appcast.xml.
#
# usage: scripts/package-release.sh VERSION BUILD TAG
# env:   SPARKLE_PRIVATE_KEY  base64 Ed25519 seed (required)
#        SIGNING_CERT_P12     base64 PKCS#12 with "Scribe Sync Signing" (optional; ad-hoc if missing)
#        SIGNING_CERT_PASS    PKCS#12 password (default: scribesync)
#        GITHUB_REPOSITORY    owner/repo for the download URL
#        SPARKLE_VERSION      Sparkle tools version (default 2.10.1)
set -euo pipefail
VERSION="$1"; BUILD="$2"; TAG="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Build/Products/Release/Scribe Sync.app"
WORK="${RUNNER_TEMP:-$(mktemp -d)}"
test -d "$APP"
test -n "${SPARKLE_PRIVATE_KEY:-}" || { echo "::error::SPARKLE_PRIVATE_KEY missing"; exit 1; }

# 1. code signature
if [ -n "${SIGNING_CERT_P12:-}" ]; then
  KC="$WORK/signing.keychain-db"
  security delete-keychain "$KC" 2>/dev/null || true
  security create-keychain -p ci "$KC"
  security set-keychain-settings -lut 3600 "$KC"
  security unlock-keychain -p ci "$KC"
  echo "$SIGNING_CERT_P12" | base64 --decode > "$WORK/signing.p12"
  security import "$WORK/signing.p12" -k "$KC" -P "${SIGNING_CERT_PASS:-scribesync}" -T /usr/bin/codesign
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  security set-key-partition-list -S apple-tool:,apple: -s -k ci "$KC" >/dev/null
  security find-certificate -c "Scribe Sync Signing" -p "$KC" > "$WORK/cert.pem"
  sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$WORK/cert.pem"
  codesign --force --deep --timestamp=none --sign "Scribe Sync Signing" --keychain "$KC" "$APP"
else
  echo "::warning::SIGNING_CERT_P12 missing – ad-hoc signature (macOS asks for permissions again after updates)"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|Identifier|Signature" || true

# 2. zip + Sparkle EdDSA signature
ZIP="$ROOT/ScribeSync-${VERSION}.zip"
rm -f "$ZIP"
( cd "$(dirname "$APP")" && ditto -c -k --sequesterRsrc --keepParent "Scribe Sync.app" "$ZIP" )
SV="${SPARKLE_VERSION:-2.10.1}"
if [ ! -x "$WORK/sparkle/bin/sign_update" ]; then
  curl -sSfL -o "$WORK/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/${SV}/Sparkle-${SV}.tar.xz"
  mkdir -p "$WORK/sparkle" && tar -xf "$WORK/sparkle.tar.xz" -C "$WORK/sparkle"
fi
SIG_LINE=$(echo "$SPARKLE_PRIVATE_KEY" | "$WORK/sparkle/bin/sign_update" --ed-key-file - "$ZIP")
echo "$SIG_LINE"
SIG=$(echo "$SIG_LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
echo "$SPARKLE_PRIVATE_KEY" | "$WORK/sparkle/bin/sign_update" --ed-key-file - --verify "$ZIP" "$SIG"
LEN=$(stat -f%z "$ZIP")

# 3. appcast
NOTES="$ROOT/docs/releases/${VERSION}.md"
if [ ! -f "$NOTES" ]; then
  NOTES="$WORK/notes.md"
  git -C "$ROOT" tag -l --format='%(contents)' "$TAG" > "$NOTES" 2>/dev/null || true
  [ -s "$NOTES" ] || echo "Scribe Sync ${VERSION}" > "$NOTES"
fi
python3 "$ROOT/scripts/make_appcast.py" "$VERSION" "$BUILD" \
  "https://github.com/${GITHUB_REPOSITORY:-ata88/kindle-scribe-sync}/releases/download/${TAG}/ScribeSync-${VERSION}.zip" \
  "$LEN" "$SIG" "$NOTES" "$ROOT/appcast.xml"
echo "ZIP=$ZIP"
echo "NOTES=$NOTES"
if [ -n "${GITHUB_ENV:-}" ]; then echo "ZIP=$ZIP" >> "$GITHUB_ENV"; echo "NOTES=$NOTES" >> "$GITHUB_ENV"; fi
