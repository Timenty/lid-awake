#!/bin/zsh
# LidAwake — установка/обновление одной командой:
#   curl -fsSL https://raw.githubusercontent.com/Timenty/lid-awake/main/get.sh | zsh
#
# Скачивает последний релиз через curl (без пометки «скачано из интернета» → macOS не блокирует запуск),
# ставит в /Applications (или ~/Applications без прав администратора) и запускает.
set -euo pipefail

URL="https://github.com/Timenty/lid-awake/releases/latest/download/LidAwake.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "☕ Скачиваю LidAwake…"
curl -fsSL "$URL" -o "$TMP/LidAwake.zip"
ditto -x -k "$TMP/LidAwake.zip" "$TMP/x"
APP=$(find "$TMP/x" -maxdepth 3 -name LidAwake.app -type d | head -1)
[[ -n "$APP" ]] || { echo "❌ В архиве нет LidAwake.app"; exit 1; }

DEST=/Applications
[[ -w $DEST ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

# Старая версия: корректный выход (она сама вернёт сон, если была включена).
if pgrep -x LidAwake >/dev/null; then
  osascript -e 'quit app "LidAwake"' 2>/dev/null || true
  for _ in {1..20}; do pgrep -x LidAwake >/dev/null || break; sleep 0.25; done
fi

rm -rf "$DEST/LidAwake.app"
ditto "$APP" "$DEST/LidAwake.app"
xattr -cr "$DEST/LidAwake.app" 2>/dev/null || true
open "$DEST/LidAwake.app"

echo "✅ Готово: $DEST/LidAwake.app — кружка в строке меню справа вверху."
echo "   Клик — вкл/выкл. Правый клик — таймер, защита, выход."
echo "   При первом включении macOS один раз спросит пароль."
echo "   Автозапуск: Системные настройки → Основные → Объекты входа → «+» → LidAwake."
