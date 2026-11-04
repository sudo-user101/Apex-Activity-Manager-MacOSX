#!/bin/bash
# Builds "Apex Activity Manager.app" (native SwiftUI) into ./dist.
#   ./build.sh               release build for this Mac's architecture
#   ./build.sh --universal   Apple Silicon + Intel in one binary
#   ./build.sh --dmg         also create a .dmg
#   ./build.sh --notarize    sign with Developer ID, notarize and staple
#                            (the app, and the .dmg with --dmg)
# Build products go to a temp directory so cloud-synced folders stay clean;
# override with BUILD_DIR=/path ./build.sh
#
# Signing and notarization read everything from the environment (nothing is
# stored in this repository; see docs/RELEASING.md):
#   APEX_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)" (or its SHA-1).
#                        Unset: ad-hoc signing for local use, as before.
#   APEX_KEYCHAIN        optional keychain holding that identity (CI)
#   APEX_NOTARY_PROFILE  a `xcrun notarytool store-credentials` profile, or:
#   APEX_APPLE_ID, APEX_TEAM_ID, APEX_APP_PASSWORD (app-specific password)
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0; DMG=0; NOTARIZE=0
for a in "$@"; do
  case "$a" in
    --universal) UNIVERSAL=1 ;;
    --dmg) DMG=1 ;;
    --notarize) NOTARIZE=1 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

IDENTITY="${APEX_SIGN_IDENTITY:-}"
if [ "$NOTARIZE" = 1 ]; then
  [ -n "$IDENTITY" ] || { echo "--notarize needs APEX_SIGN_IDENTITY (a Developer ID Application identity)" >&2; exit 1; }
  if [ -n "${APEX_NOTARY_PROFILE:-}" ]; then
    NOTARY_AUTH=(--keychain-profile "$APEX_NOTARY_PROFILE")
    [ -n "${APEX_KEYCHAIN:-}" ] && NOTARY_AUTH+=(--keychain "$APEX_KEYCHAIN")
  elif [ -n "${APEX_APPLE_ID:-}" ] && [ -n "${APEX_TEAM_ID:-}" ] && [ -n "${APEX_APP_PASSWORD:-}" ]; then
    NOTARY_AUTH=(--apple-id "$APEX_APPLE_ID" --team-id "$APEX_TEAM_ID" --password "$APEX_APP_PASSWORD")
  else
    echo "--notarize needs APEX_NOTARY_PROFILE, or APEX_APPLE_ID + APEX_TEAM_ID + APEX_APP_PASSWORD" >&2; exit 1
  fi
fi
KEYCHAIN_ARGS=()
[ -n "${APEX_KEYCHAIN:-}" ] && KEYCHAIN_ARGS=(--keychain "$APEX_KEYCHAIN")

# sign PATH ENTITLEMENTS [IDENTIFIER]: Developer ID with the hardened runtime
# and a secure timestamp, or ad-hoc when no identity is set. Ad-hoc builds get
# the hardened runtime too: without it another program could start Apex with
# its own code loaded (DYLD_INSERT_LIBRARIES) and borrow Apex's permissions.
sign() {
  if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp --entitlements "$2" ${3:+--identifier "$3"} \
      ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$1"
  else
    # APEX_LOCAL_IDENTITY: the same identity on every build, so permissions granted
    # in System Settings keep working after an update. Ad-hoc signing ties them to
    # one build's exact hash instead.
    codesign --force --options runtime --entitlements "$2" ${3:+--identifier "$3"} --sign "${APEX_LOCAL_IDENTITY:--}" --timestamp=none "$1" >/dev/null
  fi
}

# notarize FILE: submit, wait, and stop with Apple's log if it isn't accepted.
notarize() {
  echo "Notarizing $(basename "$1")…"
  local out id status
  out="$(xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --output-format json)"
  id="$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    echo "Notarization was not accepted (status: ${status:-unknown})." >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
    exit 1
  fi
}

BUILD_DIR="${BUILD_DIR:-${TMPDIR:-/tmp}/taskmanager-native-build}"
ARCH_ARGS=()
[ "$UNIVERSAL" = 1 ] && ARCH_ARGS=(--arch arm64 --arch x86_64)

swift build -c release --scratch-path "$BUILD_DIR" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

APP="dist/Apex Activity Manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TaskManager" "$APP/Contents/MacOS/TaskManager"
cp "$BIN_DIR/ApexFanHelper" "$APP/Contents/MacOS/apex-fanhelper"   # privileged fan helper (installed on demand)
strip -x "$APP/Contents/MacOS/apex-fanhelper" 2>/dev/null || true
cp "$BIN_DIR/ApexSignal" "$APP/Contents/MacOS/apex-signal"         # ends / pauses processes as administrator, by identity
strip -x "$APP/Contents/MacOS/apex-signal" 2>/dev/null || true
strip -x "$APP/Contents/MacOS/TaskManager" 2>/dev/null || true
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/apex-agent.py "$APP/Contents/Resources/apex-agent.py"   # sent to servers over SSH (Servers page)
cp Resources/apex-docker.py "$APP/Contents/Resources/apex-docker.py" # Docker Management over SSH
# Sign the nested helper first (strip removes the linker's signature on universal builds).
# Its identifier matches its LaunchDaemon label.
sign "$APP/Contents/MacOS/apex-fanhelper" Resources/ApexFanHelper.entitlements com.apex.fanhelper
sign "$APP/Contents/MacOS/apex-signal" Resources/ApexSignal.entitlements com.apex.signal
sign "$APP" Resources/Apex.entitlements
if [ -n "$IDENTITY" ]; then
  codesign --verify --strict --deep "$APP"
  echo "Signed with $IDENTITY"
fi
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "$NOTARIZE" = 1 ]; then
  # The app is notarized and stapled on its own, so it keeps its ticket
  # after it's copied out of the disk image (and opens offline).
  ZIP="$BUILD_DIR/apex-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

if [ "$DMG" = 1 ]; then
  # Installer disk image: the app next to an Applications shortcut, so
  # installing is one drag. Staged outside the synced folder.
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
  DMG_PATH="dist/Apex Activity Manager ${VERSION}.dmg"
  STAGE="$BUILD_DIR/dmg-stage"
  rm -rf "$STAGE" "$DMG_PATH"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
  hdiutil create -volname "Apex Activity Manager" -srcfolder "$STAGE" -ov -format UDRW "$BUILD_DIR/apex-rw.dmg" >/dev/null
  # Show the volume icon (custom-icon flag on the volume root).
  MNT="$(hdiutil attach -nobrowse -noverify "$BUILD_DIR/apex-rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')"
  SetFile -a C "$MNT" 2>/dev/null || true
  hdiutil detach "$MNT" -force >/dev/null
  hdiutil convert "$BUILD_DIR/apex-rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
  rm -rf "$STAGE" "$BUILD_DIR/apex-rw.dmg"
  if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$DMG_PATH"
  fi
  if [ "$NOTARIZE" = 1 ]; then
    notarize "$DMG_PATH"
    xcrun stapler staple "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
  fi
  echo "Built $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
fi
