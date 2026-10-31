#!/bin/sh
# Архив Release и .ipa для App Store Connect на Маке (без загрузки). Итог: ~/git/redtask/build/export/RedTask.ipa на Маке.
# Загрузить: UPLOAD=1 tools/archive.sh (нужен вход в аккаунт в Xcode). Перед каждой загрузкой поднимать CURRENT_PROJECT_VERSION.
set -e
MAC=toxblh@192.168.5.97
DEST=${UPLOAD:+upload}
rsync -a --delete --exclude .git --exclude build --exclude '*.xcodeproj' --exclude shots --exclude .build ~/git/redtask/ $MAC:git/redtask/
ssh $MAC "zsh -lc '
  set -e
  read -r PW; security unlock-keychain -p \"\$PW\" ~/Library/Keychains/login.keychain-db
  cd ~/git/redtask && xcodegen generate -q >/dev/null && rm -rf build/RedTask.xcarchive build/export && mkdir -p build
  xcodebuild -project RedTask.xcodeproj -scheme RedTask -configuration Release -destination generic/platform=iOS \
    -archivePath build/RedTask.xcarchive -allowProvisioningUpdates archive > build/archive.log 2>&1 \
    || { grep -E \"error|warning: .*icon\" build/archive.log | head -20; exit 1; }
  echo archive ok
  /usr/libexec/PlistBuddy -c \"Add :method string app-store-connect\" -c \"Add :destination string ${DEST:-export}\" \
    -c \"Add :teamID string MUMWZ78YDU\" build/ExportOptions.plist >/dev/null
  xcodebuild -exportArchive -archivePath build/RedTask.xcarchive -exportPath build/export \
    -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates > build/export.log 2>&1 \
    || { grep -iE \"error\" build/export.log | head -20; exit 1; }
  ls -l build/export
'" < ~/.redtask-keychain
