#!/usr/bin/env bash
# package_app.sh
#
# Builds PaperReader in release mode and assembles a standalone,
# ad-hoc-signed, double-clickable PaperReader.app bundle under dist/.
# No notarization or distribution signing is performed — this is strictly
# for local/personal use.
#
# Run from the repository root:
#   bash scripts/package_app.sh

set -euo pipefail

# --- Paths -------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACKAGING_DIR="$ROOT_DIR/packaging"
BUILD_TMP_DIR="$ROOT_DIR/build/packaging"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/PaperReader.app"

BASE_ICON_PNG="$PACKAGING_DIR/AppIcon-1024.png"
ICONSET_DIR="$BUILD_TMP_DIR/AppIcon.iconset"
ICNS_PATH="$BUILD_TMP_DIR/AppIcon.icns"

RELEASE_BINARY="$ROOT_DIR/.build/release/PaperReaderApp"

mkdir -p "$PACKAGING_DIR" "$BUILD_TMP_DIR" "$DIST_DIR"

# --- 1. Build the release binary ---------------------------------------
echo "==> Building PaperReaderApp (release)..."
swift build -c release

if [[ ! -f "$RELEASE_BINARY" ]]; then
    echo "error: expected release binary not found at $RELEASE_BINARY" >&2
    exit 1
fi

# --- 2. Determine / generate the base 1024x1024 icon --------------------
if [[ -f "$BASE_ICON_PNG" ]]; then
    echo "==> Using existing base icon at $BASE_ICON_PNG"
else
    echo "==> Generating placeholder 1024x1024 app icon..."
    ICON_GEN_SWIFT="$BUILD_TMP_DIR/generate_icon.swift"
    cat > "$ICON_GEN_SWIFT" <<'SWIFT_EOF'
import AppKit
import CoreGraphics

let size = 1024
let outputPath = CommandLine.arguments[1]

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// Rounded-rect clip (Apple-style "squircle"-ish corner radius).
let cornerRadius = CGFloat(size) * 0.2237
let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(path)
ctx.clip()

// Vertical blue -> indigo gradient.
let colorSpace = CGColorSpaceCreateDeviceRGB()
let topColor = NSColor(calibratedRed: 0.29, green: 0.56, blue: 0.98, alpha: 1.0)   // blue
let bottomColor = NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.80, alpha: 1.0) // indigo
let colors = [topColor.cgColor, bottomColor.cgColor] as CFArray
guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) else {
    fatalError("failed to create gradient")
}
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// Centered white "PR" text.
let text = "PR"
let fontSize = CGFloat(size) * 0.42
let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
let paragraphStyle = NSMutableParagraphStyle()
paragraphStyle.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraphStyle
]
let attributedString = NSAttributedString(string: text, attributes: attributes)
let textSize = attributedString.size()
let textRect = CGRect(
    x: (CGFloat(size) - textSize.width) / 2,
    y: (CGFloat(size) - textSize.height) / 2,
    width: textSize.width,
    height: textSize.height
)
attributedString.draw(in: textRect)

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("failed to render PNG data")
}

try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote placeholder icon to \(outputPath)")
SWIFT_EOF

    swift "$ICON_GEN_SWIFT" "$BASE_ICON_PNG"
fi

# --- 3. Build the .iconset and compile to .icns --------------------------
echo "==> Building iconset..."
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16     "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null
sips -z 32 32     "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png"      >/dev/null
sips -z 64 64     "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png"    >/dev/null
sips -z 256 256   "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png"    >/dev/null
sips -z 512 512   "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$BASE_ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

# --- 4. Assemble the .app bundle ------------------------------------------
echo "==> Assembling app bundle..."
rm -rf "$APP_BUNDLE"

CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$RELEASE_BINARY" "$MACOS_DIR/PaperReader"
chmod +x "$MACOS_DIR/PaperReader"

cp "$ICNS_PATH" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Paper Reader</string>
    <key>CFBundleDisplayName</key>
    <string>Paper Reader</string>
    <key>CFBundleIdentifier</key>
    <string>com.alexanderrecce.paperreader</string>
    <key>CFBundleExecutable</key>
    <string>PaperReader</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
</dict>
</plist>
PLIST_EOF

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# --- 5. Ad-hoc codesign ----------------------------------------------------
echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Verifying signature..."
codesign --verify --verbose "$APP_BUNDLE"

# --- 6. Done ----------------------------------------------------------------
echo "$APP_BUNDLE"
echo "done: PaperReader.app built, icon generated/reused, ad-hoc signed, and verified."
