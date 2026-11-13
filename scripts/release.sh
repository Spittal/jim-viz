#!/bin/zsh
# Build a release and, with --publish, put it on GitHub.
#
#   scripts/release.sh 1.2.3             # check, bundle, smoke-test, build/jim-viz-1.2.3.dmg
#   scripts/release.sh 1.2.3 --publish   # the same, then tag v1.2.3, push, GitHub release
#
# --publish needs a clean tree on main and `gh` logged in. The app is ad-hoc signed and
# not notarized (no Apple developer account), so Gatekeeper warns on first open: the release
# notes written here tell people how to get past it.
set -e
cd "${0:A:h}/.."
version=$1
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Usage: scripts/release.sh 1.2.3 [--publish]"; exit 1 }
publish=0
[[ "$2" == "--publish" ]] && publish=1
tag=v$version
dmg=build/jim-viz-$version.dmg

if (( publish )); then
  [[ $(git branch --show-current) == main ]] || { echo "Not on main."; exit 1 }
  [[ -z $(git status --porcelain) ]] || { echo "Uncommitted changes: commit or stash them first."; exit 1 }
  gh auth status >/dev/null || { echo "Log in first: gh auth login"; exit 1 }
  if git rev-parse -q --verify refs/tags/$tag >/dev/null; then echo "Tag $tag already exists."; exit 1; fi
fi
[[ $(uname -m) == arm64 ]] || { echo "Releases are built on Apple Silicon."; exit 1 }

echo "=== Self-check"
scripts/check.sh

echo "=== Bundle"
scripts/fetch-depth-model.sh
scripts/bundle.sh $version
app="build/Jim Viz.app"
[[ -d $app/Contents/Resources/Models/DepthAnythingV2SmallF16.mlpackage ]] || { echo "Depth model missing from the bundle."; exit 1 }

echo "=== Smoke test: the bundled app, its own content, an empty library"
scratch=$(mktemp -d)
scratch=${scratch:A}
trap "rm -rf $scratch" EXIT
env -u JIMVIZ_CONTENT -u JIMVIZ_MODELS JIMVIZ_LIBRARY=$scratch/library $app/Contents/MacOS/jim-viz --check

echo "=== Disk image"
stage=$scratch/dmg
mkdir -p $stage
cp -R $app $stage/
ln -s /Applications $stage/Applications
rm -f $dmg
hdiutil create -volname "Jim Viz $version" -srcfolder $stage -fs HFS+ -format ULMO -ov $dmg >/dev/null
hdiutil verify -quiet $dmg
sha=$(shasum -a 256 $dmg | cut -d' ' -f1)
echo "Built $dmg ($(du -h $dmg | cut -f1 | tr -d ' '), sha256 $sha)"

if (( ! publish )); then
  echo "Not published. Try the disk image, then run: scripts/release.sh $version --publish"
  exit 0
fi

echo "=== Publish"
notes=$scratch/notes.md
cat > $notes <<NOTES
## Install

Needs an Apple Silicon Mac on macOS 14.2 or later.

1. Download \`jim-viz-$version.dmg\`, open it, and drag **Jim Viz** into **Applications**.
2. Open it. macOS says it "could not verify" the app, because Jim Viz isn't signed with an Apple developer account. Click **Done**.
3. Open **System Settings › Privacy & Security**, scroll down to Security, and click **Open Anyway** next to Jim Viz. This is needed once per version.

Or skip steps 2 and 3 in Terminal: \`xattr -dr com.apple.quarantine "/Applications/Jim Viz.app"\`

**Updating from an earlier version:** macOS ties camera and audio permissions to the exact build, so they need granting again. If Jim Viz hears silence or sees no webcam after an update, run \`tccutil reset All com.jimviz.app\` and reopen it.

SHA-256: \`$sha\`
NOTES
git tag -a $tag -m "Jim Viz $version"
git push origin main $tag
gh release create $tag $dmg --title "Jim Viz $version" --notes-file $notes --generate-notes --verify-tag
