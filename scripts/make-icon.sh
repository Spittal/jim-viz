#!/bin/zsh
# Rebuild Resources/AppIcon.icns from a portrait photo: scripts/make-icon.sh photo.png
# Needs python3 with Pillow and numpy. The photo itself isn't kept in the repo.
set -e
photo=${1:A}
cd "${0:A:h}/.."
tmp=$(mktemp -d)
swift scripts/icon/landmarks.swift $photo $tmp/mask.png 2>/dev/null > $tmp/landmarks.json
python3 scripts/icon/ridgeline.py $photo $tmp/mask.png $tmp/landmarks.json $tmp/icon.png
cp $tmp/icon.png Resources/AppIcon.png
set=$tmp/AppIcon.iconset
mkdir $set
for s in 16 32 128 256 512; do
  sips -z $s $s $tmp/icon.png --out $set/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $tmp/icon.png --out $set/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $set -o Resources/AppIcon.icns
echo "Built Resources/AppIcon.icns and Resources/AppIcon.png"
