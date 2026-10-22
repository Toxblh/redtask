#!/bin/sh
# Синхронизация на Мак и сборка/тесты. Использование: tools/build.sh [build|test|run] [симулятор]
set -e
MAC=toxblh@192.168.5.97
# одно соединение на всё: агент ключей иногда отказывает при частых входах
SSHO="-o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm/redtask-%r@%h:%p -o ControlPersist=8h -o BatchMode=yes"
ACTION=${1:-build}
DEST=${2:-generic/platform=iOS Simulator}
rsync -a -e "ssh $SSHO" --delete --exclude .git --exclude build --exclude '*.xcodeproj' --exclude shots ~/git/redtask/ $MAC:git/redtask/
ssh $SSHO $MAC "zsh -lc 'cd ~/git/redtask && xcodegen generate -q >/dev/null && \
  xcodebuild -project RedTask.xcodeproj -scheme RedTask -destination \"$DEST\" \
  -derivedDataPath build $ACTION 2>&1 | grep -E \"error:|warning: .*(Sendable|isolat|concurren)|BUILD|TEST|Test Case.*failed|passed|failed\" | grep -v \"^ld:\" | head -80'"
