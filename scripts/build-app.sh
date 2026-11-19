#!/usr/bin/env bash
# Build "Scribe Sync.app" (Release, Apple Silicon) into build/Build/Products/Release.
# Usage: scripts/build-app.sh [version] [build-number]
set -uo pipefail
VERSION="${1:-0.0.0}"
BUILD="${2:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Build/Products/Release/Scribe Sync.app"
cd "$ROOT/App"
xcodegen generate --quiet || exit 1
START=$(date +%s)
xcodebuild \
  -project ScribeSync.xcodeproj -scheme ScribeSync -configuration Release \
  -derivedDataPath "$ROOT/build" -destination 'platform=macOS,arch=arm64' \
  -skipMacroValidation -skipPackagePluginValidation \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  build > "$ROOT/build.log" 2>&1
RC=$?
echo "xcodebuild exit $RC after $(( $(date +%s) - START )) s"
grep -E "error:|BUILD (SUCCEEDED|FAILED)|\*\* BUILD" "$ROOT/build.log" | awk '!seen[$0]++' | head -60
[ "$RC" -eq 0 ] || exit "$RC"
if [ ! -x "$APP/Contents/MacOS/Scribe Sync" ]; then
  echo "error: app bundle has no executable"
  exit 1
fi
du -sh "$APP"
echo "Built: $APP"
