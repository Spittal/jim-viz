#!/bin/zsh
# Downloads the depth model the Webcam's Depth output uses: Apple's Core ML build of
# Depth Anything V2 Small (Apache-2.0, ~50 MB) from Hugging Face.
#
# It goes to ~/Library/Application Support/jim-viz/Models, where both scripts/run.sh and the
# bundled app look. scripts/bundle.sh also copies it into the app if it's there.
set -euo pipefail

NAME=DepthAnythingV2SmallF16
BASE="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/$NAME.mlpackage"
DEST="${JIMVIZ_MODELS:-$HOME/Library/Application Support/jim-viz/Models}"
PKG="$DEST/$NAME.mlpackage"

if [[ -f "$PKG/Data/com.apple.CoreML/weights/weight.bin" ]]; then
    echo "Already there: $PKG"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    echo "Downloading $f"
    mkdir -p "$TMP/$NAME.mlpackage/$(dirname "$f")"
    curl -fL --progress-bar -o "$TMP/$NAME.mlpackage/$f" "$BASE/$f"
done
mkdir -p "$DEST"
rm -rf "$PKG"
mv "$TMP/$NAME.mlpackage" "$PKG"
echo "Saved $PKG"
