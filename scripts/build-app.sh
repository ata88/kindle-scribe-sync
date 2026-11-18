#!/usr/bin/env bash
# Build "Scribe Sync.app" (Release, Apple Silicon) into build/Build/Products/Release.
# Usage: scripts/build-app.sh [version] [build-number]
set -euo pipefail
VERSION="${1:-0.0.0}"
BUILD="${2:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/App"
xcodegen generate --quiet
set -o pipefail
xcodebuild \
  -project ScribeSync.xcodeproj -scheme ScribeSync -configuration Release \
  -derivedDataPath "$ROOT/build" -destination 'platform=macOS,arch=arm64' \
  -skipMacroValidation -skipPackagePluginValidation \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$ROOT/build.log" | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)|Resolve Package" || true
test "${PIPESTATUS[0]}" -eq 0
test -d "$ROOT/build/Build/Products/Release/Scribe Sync.app"
echo "Built: $ROOT/build/Build/Products/Release/Scribe Sync.app"
