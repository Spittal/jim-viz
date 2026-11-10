#!/bin/zsh
# Compile every shader, render every scene offscreen with a synthetic 124 BPM track feeding
# the audio analyzer, and score onset detection and beat tracking against known hit times.
# Pass a directory to also write a PNG snapshot of each scene: scripts/check.sh /tmp/snaps
# Runs on a scratch copy of your library (~/Library/Application Support/jim-viz), so your
# scenes, presets and playlists are checked but never written to.
set -e
cd "${0:A:h}/.."
swift build
mkdir -p .build/testdata
track=.build/testdata/test124.wav
truth=.build/testdata/truth.txt
padded=.build/testdata/test124-pad.wav
[[ -f $track ]] || python3 scripts/testdata/gen_test_track.py $track $truth
[[ -f $padded ]] || python3 scripts/testdata/add_pad.py $track $padded
args=(--check --audio $track)
[[ -n "$1" ]] && args+=(--snapshot "$1")
src="$HOME/Library/Application Support/jim-viz"
scratch=$(mktemp -d)
scratch=${scratch:A}  # /var is a symlink; the checks compare file URLs
trap "rm -rf $scratch" EXIT
for d in Scenes Presets Playlists; do if [[ -d "$src/$d" ]]; then cp -R "$src/$d" $scratch/; fi; done
for d in Videos Pictures; do if [[ -d "$src/$d" ]]; then ln -s "$src/$d" $scratch/$d; fi; done
JIMVIZ_CONTENT="$PWD/Content" JIMVIZ_LIBRARY=$scratch .build/debug/JimViz $args
echo "--- onset detection and beat tracking"
# The bare track is only drums and a plucked sine bass, which the stem separator can't tell
# apart: it puts the lot in the drum stem, so some bass notes count as kicks. Under the pad
# (below) there is music to separate, and the kicks must be clean.
JIMVIZ_CONTENT="$PWD/Content" .build/debug/JimViz --analyze $track --truth $truth --expect-bpm 124 --kick-precision 0.6
echo "--- onset detection and beat tracking under a pad"
JIMVIZ_CONTENT="$PWD/Content" .build/debug/JimViz --analyze $padded --truth $truth --expect-bpm 124
