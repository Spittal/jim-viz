#!/bin/zsh
# Build a release .app into build/JimViz.app. Shaders and maps are bundled and read from the
# app; scenes, presets and playlists live in ~/Library/Application Support/jim-viz.
set -e
cd "${0:A:h}/.."
swift build -c release
app=build/JimViz.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources/Content
cp .build/release/JimViz $app/Contents/MacOS/JimViz
cp -R Content/Shaders Content/Maps Content/Models $app/Contents/Resources/Content/
# The depth model (scripts/fetch-depth-model.sh), if it's been fetched.
model="$HOME/Library/Application Support/jim-viz/Models/DepthAnythingV2SmallF16.mlpackage"
if [[ -d $model ]]; then
  mkdir -p $app/Contents/Resources/Models
  cp -R $model $app/Contents/Resources/Models/
else
  echo "Note: no depth model; Webcam Depth won't work in this build. Run scripts/fetch-depth-model.sh first."
fi
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>jim-viz</string>
  <key>CFBundleDisplayName</key><string>jim-viz</string>
  <key>CFBundleIdentifier</key><string>com.jimviz.app</string>
  <key>CFBundleExecutable</key><string>JimViz</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>jim-viz uses the webcam as a texture and signal source.</string>
  <key>NSAudioCaptureUsageDescription</key><string>jim-viz listens to Rekordbox's audio to drive the visuals.</string>
</dict>
</plist>
PLIST
codesign --force --sign - $app
echo "Built $app"
