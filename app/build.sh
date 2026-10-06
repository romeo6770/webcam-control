#!/bin/zsh
# Compila UVCControl sin Xcode y lo empaqueta como .app
set -e
cd "$(dirname "$0")"

APP="Webcam Control.app"
swiftc -O -parse-as-library \
  UVC.swift CameraModel.swift UVCControlApp.swift \
  -framework IOKit -framework AVFoundation -framework SwiftUI \
  -o UVCControl

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv UVCControl "$APP/Contents/MacOS/"

# Icono: icon.png (ideal 1024x1024) -> AppIcon.icns
ICON_KEY=""
if [[ -f icon.png ]]; then
  rm -rf AppIcon.iconset && mkdir AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) icon.png --out "AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf AppIcon.iconset
  ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UVCControl</string>
  <key>CFBundleIdentifier</key><string>com.digitalsea.webcamcontrol</string>
  <key>CFBundleName</key><string>Webcam Control</string>
  <key>CFBundleDisplayName</key><string>Webcam Control</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCameraUsageDescription</key><string>Preview en vivo de la cámara.</string>
  <key>NSHighResolutionCapable</key><true/>
$ICON_KEY
</dict>
</plist>
EOF

# Firma ad-hoc para que el permiso de cámara quede asociado a la app
codesign --force --sign - "$APP"

# Que Finder/Dock refresquen el icono
touch "$APP"

echo "Listo: $APP"
open "$APP"
