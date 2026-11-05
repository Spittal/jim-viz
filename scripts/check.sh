#!/bin/zsh
# Compile every shader, render every scene offscreen with a synthetic 124 BPM track feeding
# the audio analyzer, and score onset detection against known hit times.
# Pass a directory to also write a PNG snapshot of each scene: scripts/check.sh /tmp/snaps
set -e
cd "${0:A:h}/.."
swift build
mkdir -p .build/testdata
track=.build/testdata/test124.wav
truth=.build/testdata/truth.txt
[[ -f $track ]] || python3 scripts/testdata/gen_test_track.py $track $truth
args=(--check --audio $track)
[[ -n "$1" ]] && args+=(--snapshot "$1")
JIMVIZ_CONTENT="$PWD/Content" .build/debug/JimViz $args
echo "--- onset detection"
.build/debug/JimViz --analyze $track --truth $truth
