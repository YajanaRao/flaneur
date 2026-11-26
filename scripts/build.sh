#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
app="$HOME/Applications/Flaneur.app"
swift build -c release --package-path "$root"
bin_dir=$(swift build -c release --package-path "$root" --show-bin-path)

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/flaneur" "$app/Contents/MacOS/flaneur"
rm -rf "$app/Contents/MacOS/flaneur_FlaneurKit.bundle"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/GitHubMark.pdf" "$app/Contents/Resources/GitHubMark.pdf"
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
src="$root/Resources/AppIcon-512.png"
for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" "64:icon_32x32@2x.png" "128:icon_128x128.png" "256:icon_128x128@2x.png" "256:icon_256x256.png" "512:icon_256x256@2x.png" "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
  size=${spec%%:*}
  name=${spec#*:}
  sips -z "$size" "$size" "$src" --out "$iconset/$name" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
chmod 755 "$app/Contents/MacOS/flaneur"
codesign --force --sign - "$app"
echo "$app"
