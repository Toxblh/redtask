#!/bin/sh
# Сборка и установка на подключённый к Маку iPhone. Связка ключей разблокируется только в своей ssh-сессии,
# поэтому всё в одном заходе; пароль от Мака берётся из локального ~/.redtask-keychain (chmod 600) и идёт через stdin.
set -e
MAC=toxblh@192.168.5.97
DEV=${1:-00008110-001525563E84801E}
rsync -a --delete --exclude .git --exclude build --exclude '*.xcodeproj' --exclude shots --exclude .build ~/git/redtask/ $MAC:git/redtask/
ssh -o ControlPath=none $MAC "zsh -lc '
  set -e
  read -r PW; security unlock-keychain -p \"\$PW\" ~/Library/Keychains/login.keychain-db
  cd ~/git/redtask && xcodegen generate -q >/dev/null && mkdir -p build
  xcodebuild -project RedTask.xcodeproj -scheme RedTask -configuration Debug -destination id=$DEV -derivedDataPath build \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > build/device.log 2>&1 || { grep error build/device.log | head -20; exit 1; }
  echo build ok
  xcrun devicectl device install app --device $DEV build/Build/Products/Debug-iphoneos/RedTask.app 2>&1 | tail -2
  xcrun devicectl device process launch --device $DEV ru.toxblh.RedTask 2>&1 | tail -1
'" < ~/.redtask-keychain
