#!/bin/sh
# Установка собранного приложения в симулятор, запуск и скриншот.
# tools/sim.sh <udid> [shot-name] [extra simctl launch args...]
MAC=toxblh@192.168.5.97
SSHO="-o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm/redtask-%r@%h:%p -o ControlPersist=8h -o BatchMode=yes"
UDID=$1; SHOT=$2; shift 2
ssh $SSHO $MAC "zsh -lc 'xcrun simctl boot $UDID 2>/dev/null; xcrun simctl bootstatus $UDID -b >/dev/null; \
  xcrun simctl install $UDID ~/git/redtask/build/Build/Products/Debug-iphonesimulator/RedTask.app && \
  xcrun simctl terminate $UDID ru.toxblh.RedTask 2>/dev/null; xcrun simctl launch $UDID ru.toxblh.RedTask $* && sleep 4 && \
  ([ -n \"$SHOT\" ] && xcrun simctl io $UDID screenshot /tmp/$SHOT.png >/dev/null 2>&1; true)'"
if [ -n "$SHOT" ]; then mkdir -p ~/git/redtask/shots; scp -q -o ControlPath=$HOME/.ssh/cm/redtask-%r@%h:%p $MAC:/tmp/$SHOT.png ~/git/redtask/shots/; fi
