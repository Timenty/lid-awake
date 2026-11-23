#!/bin/zsh
# Демо сирены LidAwake. Собирает (если нужно) и запускает.
#   ./demo/siren.sh         — ждёт закрытия крышки
#   ./demo/siren.sh --now   — играет сразу
set -e
cd "$(dirname "$0")"
BIN=.build/siren
if [[ ! -x $BIN || main.swift -nt $BIN || ../Safety.swift -nt $BIN ]]; then
  mkdir -p .build
  swiftc -O main.swift ../Safety.swift -o $BIN
fi
exec $BIN "$@"
