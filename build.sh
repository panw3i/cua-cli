#!/bin/sh
# Build build/CUA.app (settings window with the CLI and installer inside) and dist/CUA-VERSION.zip.
set -eu
VERSION=${VERSION:-0.1.0}
cd "$(dirname "$0")"
app=build/CUA.app
rm -rf build && mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/cli/bin" dist

swift app/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"

swiftc -O -parse-as-library -target arm64-apple-macos14 app/CUAApp.swift -o "$app/Contents/MacOS/CUA"

cp cua.mjs install.sh "$app/Contents/Resources/cli/"
cp bin/cua "$app/Contents/Resources/cli/bin/"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CUA</string>
  <key>CFBundleDisplayName</key><string>Computer Use</string>
  <key>CFBundleIdentifier</key><string>cc.cua.settings</string>
  <key>CFBundleExecutable</key><string>CUA</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$app"
ditto -c -k --keepParent "$app" "dist/CUA-$VERSION.zip"
echo "built $app and dist/CUA-$VERSION.zip"
