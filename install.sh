#!/bin/zsh
# Ставит sudoers-правило (pmset disablesleep 0/1 без пароля) и копирует app в /Applications.
set -e
cd "$(dirname "$0")"
./build.sh
U=$(id -un)
TMP=$(mktemp)
echo "$U ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" > $TMP
chmod 644 $TMP
# GUI-запрос пароля — работает и без TTY.
osascript -e "do shell script \"/usr/sbin/visudo -cf $TMP && /usr/bin/install -m 0440 -o root -g wheel $TMP /etc/sudoers.d/lidawake\" with administrator privileges"
rm -f $TMP
sudo -n /usr/bin/pmset -a disablesleep 0 && echo "sudoers OK"
pkill -x LidAwake || true
rm -rf /Applications/LidAwake.app
cp -R LidAwake.app /Applications/
open /Applications/LidAwake.app
echo "OK. Автозапуск: System Settings → General → Login Items → + LidAwake"
