#!/bin/bash
# Build, package and publish a "Kero Remote" release on the fork
# (github.com/benjaminv/kero). Ad-hoc signed: installers clear quarantine
# with `xattr -dr com.apple.quarantine`. Upstream's Sparkle release
# (scripts/release.ts) is untouched.
#
# Usage: ./scripts/release-remote.sh [--publish] [--prerelease]
#   Without --publish it builds and packages only, and prints the notes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

PUBLISH=0
PRERELEASE_FLAG=""
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --prerelease) PRERELEASE_FLAG="--prerelease" ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

PBXPROJ="kero.xcodeproj/project.pbxproj"
VERSION=$(grep -m1 'MARKETING_VERSION' "$PBXPROJ" | sed 's/.*= \(.*\);/\1/')
TAG="v${VERSION}"
APP_NAME="Kero Remote"
BUNDLE_ID="sh.kero.remote"
DERIVED="${TMPDIR:-/tmp}/kero-remote-release-dd"
OUT="$PROJECT_ROOT/build/remote-release"
TARBALL="$OUT/Kero-Remote-darwin-arm64.app.tar.gz"
NOTES="$OUT/release-notes.md"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "==> Version: ${VERSION} (tag: ${TAG})"

if ! git diff --quiet -- "$PBXPROJ"; then
  echo "ERROR: $PBXPROJ has uncommitted changes; commit or revert them first." >&2
  exit 1
fi

# The bundle identifier must be target-scoped. Passing it on the xcodebuild
# command line stamps every SwiftPM resource bundle with it too, and asset
# lookups (keyed by bundle identifier) then resolve against the wrong
# catalogue and crash the editor.
restore_pbxproj() { git checkout -q -- "$PBXPROJ"; }
trap restore_pbxproj EXIT
sed -i '' "s/PRODUCT_BUNDLE_IDENTIFIER = sh.kero;/PRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE_ID};/" "$PBXPROJ"
grep -q "PRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE_ID};" "$PBXPROJ" || {
  echo "ERROR: could not set the Release bundle identifier in $PBXPROJ" >&2; exit 1; }

echo "==> Building ${APP_NAME} (Release)..."
rm -rf "$DERIVED"
xcodebuild -project kero.xcodeproj -scheme kero -configuration Release \
  -derivedDataPath "$DERIVED" \
  KERO_DISPLAY_NAME="$APP_NAME" \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Remote \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build -quiet
restore_pbxproj
trap - EXIT

APP="$DERIVED/Build/Products/Release/${APP_NAME}.app"
[ -d "$APP" ] || { echo "ERROR: app not found at $APP" >&2; exit 1; }

echo "==> Checking bundle identifiers..."
[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] \
  || { echo "ERROR: app bundle identifier is not $BUNDLE_ID" >&2; exit 1; }
for b in "$APP/Contents/Resources/"*.bundle; do
  if [ "$(plutil -extract CFBundleIdentifier raw "$b/Contents/Info.plist")" = "$BUNDLE_ID" ]; then
    echo "ERROR: nested bundle carries the app identifier: $b" >&2; exit 1
  fi
done

# The embedded Sparkle framework's signature must match the ad-hoc main
# binary or dyld refuses to launch the app.
echo "==> Signing (ad hoc)..."
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Packaging..."
mkdir -p "$OUT"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$(dirname "$APP")" "${APP_NAME}.app"

echo "==> Generating release notes..."
PREV_TAG=$(git tag --sort=-version:refname | grep -v "^${TAG}$" | head -1 || true)
if [ -z "$PREV_TAG" ]; then
  COMMITS=$(git log --format="- %s" -20)
else
  COMMITS=$(git log --format="- %s" "${PREV_TAG}..HEAD")
fi
cat > "$NOTES" <<NOTES_EOF
## What's new

${COMMITS}

## Downloads

- **Kero-Remote-darwin-arm64.app.tar.gz** - macOS app (Apple Silicon)

> The app is ad-hoc signed. After extracting to /Applications, run:
>
> \`\`\`
> xattr -dr com.apple.quarantine "/Applications/Kero Remote.app"
> \`\`\`
NOTES_EOF

echo ""
echo "==> Release notes:"
echo "---"
cat "$NOTES"
echo "---"
echo "==> Tarball: $TARBALL ($(du -h "$TARBALL" | cut -f1))"

if [ "$PUBLISH" -ne 1 ]; then
  echo ""
  echo "Dry run complete. Re-run with --publish to tag and create the release."
  exit 0
fi

echo "==> Switching to benjaminv account..."
gh auth switch -u benjaminv
trap 'gh auth switch -u dc-benh' EXIT

echo "==> Tagging ${TAG}..."
git tag "$TAG"
git push origin "$TAG"

echo "==> Creating release on benjaminv/kero..."
gh release create "$TAG" \
  --repo benjaminv/kero \
  --title "Kero Remote ${TAG}" \
  --notes-file "$NOTES" \
  $PRERELEASE_FLAG \
  "$TARBALL"

echo ""
echo "Done: https://github.com/benjaminv/kero/releases/tag/${TAG}"
