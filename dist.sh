#!/bin/zsh
# Собирает LidAwake.zip для коллег.
set -e
cd "$(dirname "$0")"
./build.sh
rm -rf dist && mkdir -p dist/LidAwake
cp -R LidAwake.app dist/LidAwake/
cp "How to install.txt" "Как установить.txt" dist/LidAwake/
(cd dist && ditto -c -k --keepParent LidAwake LidAwake.zip)
echo "→ dist/LidAwake.zip"
