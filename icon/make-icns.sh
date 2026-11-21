#!/bin/sh
# Makes Lid.icns from lid.svg: renders the SVG at each iconset size
# (macOS draws SVG natively), then runs iconutil. ./dmg.sh copies the result.
set -eu
cd "$(dirname "$0")"
set_dir=$(mktemp -d)/Lid.iconset
mkdir -p "$set_dir"
cat > "$set_dir/../render.swift" <<'SWIFT'
import AppKit
let a = CommandLine.arguments
let svg = NSImage(contentsOfFile: a[1])!
let px = Int(a[3])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SWIFT
swiftc -o "$set_dir/../render" "$set_dir/../render.swift"
for s in 16 32 128 256 512; do
  "$set_dir/../render" lid.svg "$set_dir/icon_${s}x${s}.png" $s
  "$set_dir/../render" lid.svg "$set_dir/icon_${s}x${s}@2x.png" $((s * 2))
done
iconutil -c icns "$set_dir" -o Lid.icns
echo icon/Lid.icns
