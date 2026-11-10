#!/bin/zsh
# Build a release .app into build/JimViz.app: scripts/bundle.sh [version]
# The version defaults to the latest git tag (v1.2.3 → 1.2.3), or 0.0.0 before the first tag.
# Shaders, maps and models are bundled and read from the app; scenes, presets and playlists
# live in ~/Library/Application Support/jim-viz.
set -e
cd "${0:A:h}/.."
version=${1:-${$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo v0.0.0)#v}}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3 (got $version)"; exit 1 }
build=$(git rev-list --count HEAD)  # CFBundleVersion: goes up with every commit
swift build -c release
app=build/JimViz.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources/Content
cp .build/release/JimViz $app/Contents/MacOS/JimViz
cp -R Content/Shaders Content/Maps Content/Models $app/Contents/Resources/Content/
cp Resources/AppIcon.icns $app/Contents/Resources/
# The depth model (scripts/fetch-depth-model.sh), if it's been fetched.
model="$HOME/Library/Application Support/jim-viz/Models/DepthAnythingV2SmallF16.mlpackage"
if [[ -d $model ]]; then
  mkdir -p $app/Contents/Resources/Models
  cp -R $model $app/Contents/Resources/Models/
else
  echo "Note: no depth model; Webcam Depth won't work in this build. Run scripts/fetch-depth-model.sh first."
fi
find $app -name .DS_Store -delete
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleName</key><string>jim-viz</string>
  <key>CFBundleDisplayName</key><string>jim-viz</string>
  <key>CFBundleIdentifier</key><string>com.jimviz.app</string>
  <key>CFBundleExecutable</key><string>JimViz</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>jim-viz uses the webcam as a texture and signal source.</string>
  <key>NSAudioCaptureUsageDescription</key><string>jim-viz listens to Rekordbox or the system's audio to drive the visuals.</string>
  <key>NSMicrophoneUsageDescription</key><string>jim-viz listens to the audio input you choose to drive the visuals.</string>
</dict>
</plist>
PLIST
plutil -lint -s $app/Contents/Info.plist
# Ad-hoc signature: Apple Silicon won't run unsigned code. It is not a Developer ID, so
# Gatekeeper still warns on other Macs (scripts/release.sh writes the way past it into the release notes).
codesign --force --sign - $app
codesign --verify --deep --strict $app
echo "Built $app ($version, build $build)"
