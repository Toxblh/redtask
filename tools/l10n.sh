#!/bin/sh
# Обновление String Catalog: экспорт строк из кода (xcodebuild -exportLocalizations), перевод из tools/ru.py,
# импорт обратно и копия Localizable.xcstrings сюда. Непереведённые строки печатаются.
set -e
MAC=toxblh@192.168.5.97
CP="-o ControlPath=$HOME/.ssh/cm/redtask-%r@%h:%p"
TMP=$(mktemp -d)
rsync -a -e "ssh $CP" --delete --exclude .git --exclude build --exclude '*.xcodeproj' --exclude shots --exclude .build ~/git/redtask/ $MAC:git/redtask/
ssh $CP $MAC "zsh -lc 'cd ~/git/redtask && xcodegen generate -q && rm -rf /tmp/loc && xcodebuild -exportLocalizations -project RedTask.xcodeproj -localizationPath /tmp/loc -exportLanguage ru -sdk iphonesimulator >/dev/null 2>&1'"
scp -q -r $CP $MAC:/tmp/loc/ru.xcloc $TMP/
python3 -I ~/git/redtask/tools/fill_xliff.py "$TMP/ru.xcloc/Localized Contents/ru.xliff"
scp -q -r $CP $TMP/ru.xcloc $MAC:/tmp/loc/
ssh $CP $MAC "zsh -lc 'cd ~/git/redtask && xcodebuild -importLocalizations -project RedTask.xcodeproj -localizationPath /tmp/loc/ru.xcloc >/dev/null 2>&1'"
scp -q $CP $MAC:git/redtask/RedTask/Resources/Localizable.xcstrings ~/git/redtask/RedTask/Resources/
rm -rf $TMP
