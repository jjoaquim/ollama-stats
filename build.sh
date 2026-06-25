#!/bin/bash
# Build OllamaDashboard.swift into a proper macOS .app bundle.
#
# A bundled app has a stable identity, which makes menu-bar presence and
# floating-window activation (the "pin" feature) behave reliably. Running the
# bare compiled binary from Terminal does not give reliable window behavior.
#
# Usage:  ./build.sh        then  open ./OllamaDashboard.app
set -eo pipefail

APP="OllamaDashboard"
BUNDLE="${APP}.app"
EXEC_DIR="${BUNDLE}/Contents/MacOS"
RES_DIR="${BUNDLE}/Contents/Resources"

echo "Compiling ${APP}.swift ..."
rm -rf "${BUNDLE}"
mkdir -p "${EXEC_DIR}" "${RES_DIR}"

xcrun swiftc -O -parse-as-library "${APP}.swift" -o "${EXEC_DIR}/${APP}"

cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>${APP}</string>
  <key>CFBundleDisplayName</key>       <string>Ollama Dashboard</string>
  <key>CFBundleIdentifier</key>        <string>com.local.${APP}</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>${APP}</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Ad-hoc codesign so macOS treats it as a stable, launchable app.
codesign --force --sign - "${BUNDLE}" >/dev/null 2>&1 || true

echo "Built ${BUNDLE}"
echo "Launch with:  open ./${BUNDLE}"
