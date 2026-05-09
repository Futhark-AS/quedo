#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS_DIR="$ROOT_DIR/macos"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
VERSION="${VERSION:-${GITHUB_REF_NAME:-$(git -C "$ROOT_DIR" describe --tags --always --dirty)}}"

cd "$MACOS_DIR"
swift build -c release --product Quedo
swift build -c release --product quedo-cli

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

APP_DIR="$DIST_DIR/Quedo.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"

cp ".build/release/Quedo" "$APP_DIR/Contents/MacOS/Quedo"
chmod +x "$APP_DIR/Contents/MacOS/Quedo"

ICON_SOURCE="$ROOT_DIR/macos/Assets/quedo-app-icon.png"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
if [[ -f "$ICON_SOURCE" ]]; then
  mkdir -p "$ICONSET_DIR"
  while IFS=' ' read -r width height filename; do
    sips -z "$width" "$height" -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/$filename" >/dev/null
  done <<'EOF'
16 16 icon_16x16.png
32 32 icon_16x16@2x.png
32 32 icon_32x32.png
64 64 icon_32x32@2x.png
128 128 icon_128x128.png
256 256 icon_128x128@2x.png
256 256 icon_256x256.png
512 512 icon_256x256@2x.png
512 512 icon_512x512.png
1024 1024 icon_512x512@2x.png
EOF
  iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET_DIR"
fi

SPARKLE_SOURCE=""
if [[ -d ".build/release/Sparkle.framework" ]]; then
  SPARKLE_SOURCE=".build/release/Sparkle.framework"
elif [[ -d ".build/arm64-apple-macosx/release/Sparkle.framework" ]]; then
  SPARKLE_SOURCE=".build/arm64-apple-macosx/release/Sparkle.framework"
fi

if [[ -n "$SPARKLE_SOURCE" ]]; then
  cp -R "$SPARKLE_SOURCE" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
fi

# Make sure bundled frameworks are discoverable by @rpath.
if ! otool -l "$APP_DIR/Contents/MacOS/Quedo" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/Quedo"
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Quedo</string>
  <key>CFBundleIdentifier</key>
  <string>com.futhark.quedo</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>Quedo</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Quedo needs microphone access to record your voice for transcription.</string>
</dict>
</plist>
EOF

APP_ZIP="$DIST_DIR/Quedo.app.zip"
DMG_PATH="$DIST_DIR/Quedo.dmg"
CLI_ZIP="$DIST_DIR/quedo-cli-macos.zip"
ENTITLEMENTS_PATH="$DIST_DIR/Quedo.entitlements"
DMG_STAGING_DIR="$DIST_DIR/dmg-root"

cat > "$ENTITLEMENTS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
</dict>
</plist>
EOF

# Optional signing when identity is available in runner keychain.
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  if [[ -d "$APP_DIR/Contents/Frameworks/Sparkle.framework" ]]; then
    # Sparkle ships nested helper executables (Updater/Autoupdate/XPC services) that
    # must be re-signed with our Developer ID identity for notarization to pass.
    codesign --force --timestamp --options runtime --deep --sign "${APPLE_SIGNING_IDENTITY}" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
  fi
  codesign --force --timestamp --options runtime --sign "${APPLE_SIGNING_IDENTITY}" "$APP_DIR/Contents/MacOS/Quedo"
  codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS_PATH" --sign "${APPLE_SIGNING_IDENTITY}" "$APP_DIR"
else
  # Ensure unsigned builds still have a structurally valid bundle signature.
  # Without this, Gatekeeper can report "is damaged" for linker-signed binaries.
  if [[ -d "$APP_DIR/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --sign - "$APP_DIR/Contents/Frameworks/Sparkle.framework"
  fi
  codesign --force --sign - "$APP_DIR/Contents/MacOS/Quedo"
  codesign --force --sign - "$APP_DIR"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$APP_ZIP"
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_DIR" "$DMG_STAGING_DIR/Quedo.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "Quedo" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGING_DIR"
ditto -c -k --sequesterRsrc ".build/release/quedo-cli" "$CLI_ZIP"

if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]] && [[ -n "${APPLE_ID:-}" ]] && [[ -n "${APPLE_TEAM_ID:-}" ]] && [[ -n "${APPLE_APP_PASSWORD:-}" ]]; then
  NOTARY_RESULT_JSON="$DIST_DIR/notary-result.json"
  NOTARY_ERROR_LOG="$DIST_DIR/notary-error.log"
  ALLOW_NOTARIZATION_FAILURE="${ALLOW_NOTARIZATION_FAILURE:-false}"

  if ! xcrun notarytool submit "$DMG_PATH" \
      --apple-id "${APPLE_ID}" \
      --team-id "${APPLE_TEAM_ID}" \
      --password "${APPLE_APP_PASSWORD}" \
      --wait \
      --output-format json > "$NOTARY_RESULT_JSON" 2> "$NOTARY_ERROR_LOG"; then
    cat "$NOTARY_ERROR_LOG" >&2
    if [[ "$ALLOW_NOTARIZATION_FAILURE" == "true" ]]; then
      echo "::warning::Notarization submission failed; publishing signed but unstapled artifacts because ALLOW_NOTARIZATION_FAILURE=true." >&2
    else
      exit 1
    fi
  else
    NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT_JSON" 2>/dev/null || true)"
    if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
      NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT_JSON" 2>/dev/null || true)"
      if [[ -n "$NOTARY_ID" ]]; then
        xcrun notarytool log "$NOTARY_ID" \
          --apple-id "${APPLE_ID}" \
          --team-id "${APPLE_TEAM_ID}" \
          --password "${APPLE_APP_PASSWORD}" || true
      fi
      echo "Notarization failed with status: ${NOTARY_STATUS:-unknown}" >&2
      if [[ "$ALLOW_NOTARIZATION_FAILURE" == "true" ]]; then
        echo "::warning::Publishing signed but unstapled artifacts because ALLOW_NOTARIZATION_FAILURE=true." >&2
      else
        exit 1
      fi
    else
      xcrun stapler staple "$DMG_PATH"
    fi
  fi
fi

(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$APP_ZIP")" "$(basename "$DMG_PATH")" "$(basename "$CLI_ZIP")" > SHA256SUMS.txt
)

echo "Release artifacts ready in $DIST_DIR"
