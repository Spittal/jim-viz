#!/bin/zsh
# Build and run jim-viz against the repo's Content folder, so edits to scenes and
# shaders hot-reload live. Pass --release for an optimized build.
set -e
cd "${0:A:h}/.."
config=debug
[[ "$1" == "--release" ]] && config=release && shift
swift build -c $config
JIMVIZ_CONTENT="$PWD/Content" exec .build/$config/JimViz "$@"
