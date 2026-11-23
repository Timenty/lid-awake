#!/bin/zsh
# Release a new version:  ./release.sh 1.3.0
# VERSION → build + zip → commit, tag, push → GitHub release → Homebrew cask (version + sha256).
set -euo pipefail
cd "$(dirname "$0")"

V=${1:?usage: ./release.sh X.Y.Z}
[[ $V =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must look like 1.2.3"; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "working tree is dirty — commit first"; exit 1; }
git rev-parse -q --verify "refs/tags/v$V" >/dev/null && { echo "tag v$V already exists"; exit 1; }
gh auth status >/dev/null

echo $V > VERSION
./dist.sh
git add VERSION
git commit -q -m "Release v$V" || true   # VERSION may already hold $V
git tag "v$V"
git push -q origin HEAD "v$V"

gh release create "v$V" dist/LidAwake.zip --repo Timenty/lid-awake --title "LidAwake $V" --notes "$(cat <<EOF
## Install / update

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/Timenty/lid-awake/main/get.sh | zsh
\`\`\`

or with Homebrew:

\`\`\`sh
brew install --cask timenty/tap/lidawake   # first time
brew upgrade --cask lidawake               # update
\`\`\`

Or download \`LidAwake.zip\` below and follow \`How to install.txt\` inside.

**Changes:** https://github.com/Timenty/lid-awake/commits/v$V
EOF
)"

SHA=$(shasum -a 256 dist/LidAwake.zip | cut -d' ' -f1)
TAP=$(mktemp -d)
trap 'rm -rf "$TAP"' EXIT
git clone -q git@github.com:Timenty/homebrew-tap.git "$TAP"
sed -i '' -E "s/^  version \".*\"/  version \"$V\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/lidawake.rb"
git -C "$TAP" commit -q -am "lidawake $V"
git -C "$TAP" push -q

echo "✅ v$V released: https://github.com/Timenty/lid-awake/releases/tag/v$V"
