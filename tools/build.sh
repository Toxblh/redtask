#!/bin/sh
# Синхронизация на Мак и сборка/тесты. Использование: tools/build.sh [build|test|uitest] [назначение]
# uitest — схема RedTaskUI (XCUITest в демо-режиме), по умолчанию iPhone 17 iOS 26.5; третий аргумент — один тест:
#   tools/build.sh uitest "platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=26.5" testBell
set -e
MAC=toxblh@192.168.5.97
# одно соединение на всё: агент ключей иногда отказывает при частых входах
SSHO="-o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm/redtask-%r@%h:%p -o ControlPersist=8h -o BatchMode=yes"
ACTION=${1:-build}
SCHEME=RedTask
if [ "$ACTION" = uitest ]; then
  ACTION="test${3:+ -only-testing:RedTaskUITests/SmokeUITests/$3}"; SCHEME=RedTaskUI; DEST=${2:-platform=iOS Simulator,name=iPhone 17,OS=26.5}
fi
DEST=${DEST:-${2:-generic/platform=iOS Simulator}}
rsync -a -e "ssh $SSHO" --delete --exclude .git --exclude build --exclude '*.xcodeproj' --exclude shots --exclude .build ~/git/redtask/ $MAC:git/redtask/
ssh $SSHO $MAC "zsh -lc 'cd ~/git/redtask && xcodegen generate -q >/dev/null && \
  xcodebuild -project RedTask.xcodeproj -scheme $SCHEME -destination \"$DEST\" \
  -derivedDataPath build $ACTION 2>&1 | grep -E \"error:|warning: .*(Sendable|isolat|concurren)|BUILD|TEST|Test Case.*failed|passed|failed\" | grep -v \"^ld:\" | head -80'"
