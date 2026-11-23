#!/bin/zsh
# LidAwake — one-command install/update:
#   curl -fsSL https://raw.githubusercontent.com/Timenty/lid-awake/main/get.sh | zsh
#
# Downloads the latest release with curl (no quarantine flag → macOS doesn't block the app),
# installs it to /Applications (or ~/Applications without admin rights) and launches it.
set -euo pipefail

LANG1=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ",')
t() { [[ $LANG1 == ru* ]] && echo "$2" || echo "$1"; }

URL="https://github.com/Timenty/lid-awake/releases/latest/download/LidAwake.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

t "☕ Downloading LidAwake…" "☕ Скачиваю LidAwake…"
curl -fsSL "$URL" -o "$TMP/LidAwake.zip"
ditto -x -k "$TMP/LidAwake.zip" "$TMP/x"
APP=$(find "$TMP/x" -maxdepth 3 -name LidAwake.app -type d | head -1)
[[ -n "$APP" ]] || { t "❌ LidAwake.app not found in the archive" "❌ В архиве нет LidAwake.app"; exit 1; }

DEST=/Applications
[[ -w $DEST ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

# Quit the old version gracefully (it restores sleep itself if it was on).
if pgrep -x LidAwake >/dev/null; then
  osascript -e 'quit app "LidAwake"' 2>/dev/null || true
  for _ in {1..20}; do pgrep -x LidAwake >/dev/null || break; sleep 0.25; done
fi

rm -rf "$DEST/LidAwake.app"
ditto "$APP" "$DEST/LidAwake.app"
xattr -cr "$DEST/LidAwake.app" 2>/dev/null || true
open "$DEST/LidAwake.app"

t "✅ Installed: $DEST/LidAwake.app — look for the mug in the menu bar (top right)." \
  "✅ Готово: $DEST/LidAwake.app — кружка в строке меню справа вверху."
t "   Click — on/off. Right-click — timer, overheat protection, quit." \
  "   Клик — вкл/выкл. Правый клик — таймер, защита, выход."
t "   macOS asks for your password once, the first time you turn it on." \
  "   При первом включении macOS один раз спросит пароль."
t "   Launch at login: right-click the mug → Open at Login." \
  "   Автозапуск: правый клик по кружке → «Открывать при входе»."
