#!/bin/zsh
# Build and run jim-viz with the repo's shaders and maps, so shader edits hot-reload live.
# Scenes, presets and playlists come from ~/Library/Application Support/jim-viz.
# Pass --release for an optimized build.
set -e
cd "${0:A:h}/.."
config=debug
[[ "$1" == "--release" ]] && config=release && shift
swift build -c $config
JIMVIZ_CONTENT="$PWD/Content" exec .build/$config/JimViz "$@"
