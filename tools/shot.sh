#!/bin/sh
# tools/shot.sh <udid> <name> <wait-seconds> [launch args...] — перезапуск приложения с аргументами и скриншот
MAC=toxblh@192.168.5.97
CP="-o ControlPath=$HOME/.ssh/cm/redtask-%r@%h:%p"
UDID=$1; NAME=$2; WAIT=$3; shift 3
ssh $CP $MAC "xcrun simctl terminate $UDID ru.toxblh.RedTask 2>/dev/null; xcrun simctl launch $UDID ru.toxblh.RedTask $* >/dev/null; sleep $WAIT; xcrun simctl io $UDID screenshot /tmp/$NAME.png >/dev/null 2>&1"
mkdir -p ~/git/redtask/shots; scp -q $CP $MAC:/tmp/$NAME.png ~/git/redtask/shots/
