#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/work/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/work/modules"
mkdir -p work/cache work/modules outputs
swift build --build-system native -c release --cache-path "$PWD/work/cache" --disable-sandbox
./scripts/build-icon.sh
APP="$PWD/outputs/TermiFreedom.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TermiFreedom "$APP/Contents/MacOS/.TermiFreedom-new"
mv "$APP/Contents/MacOS/.TermiFreedom-new" "$APP/Contents/MacOS/TermiFreedom"
cp Assets/TermiFreedom.icns "$APP/Contents/Resources/TermiFreedom.icns"
cat > "$APP/Contents/Resources/askpass" <<'ASKPASS'
#!/bin/sh
exec "$(/usr/bin/dirname "$0")/../MacOS/TermiFreedom" --askpass "$@"
ASKPASS
chmod 755 "$APP/Contents/Resources/askpass"
cp Vendor/SwiftTerm/LICENSE "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
cp LICENSE "$APP/Contents/Resources/TermiFreedom-LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TermiFreedom</string>
<key>CFBundleIdentifier</key><string>app.termifreedom.mac</string>
<key>CFBundleName</key><string>TermiFreedom</string>
<key>CFBundleDisplayName</key><string>TermiFreedom</string>
<key>CFBundleIconFile</key><string>TermiFreedom</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSDocumentsFolderUsageDescription</key><string>TermiFreedom opens upload files and saves downloads you choose in Documents.</string>
<key>NSDownloadsFolderUsageDescription</key><string>TermiFreedom opens upload files and saves downloads you choose in Downloads.</string>
<key>NSDesktopFolderUsageDescription</key><string>TermiFreedom opens upload files and saves downloads you choose on your Desktop.</string>
<key>NSLocalNetworkUsageDescription</key><string>TermiFreedom connects to SSH and SFTP servers you choose on your local network.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -n "${TERMIFREEDOM_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$TERMIFREEDOM_SIGNING_IDENTITY" "$APP"
else
    codesign --force --options runtime --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
python3 scripts/check-branding.py
print "Built $APP"
