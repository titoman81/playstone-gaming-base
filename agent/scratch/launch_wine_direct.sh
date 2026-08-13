#!/bin/bash
cd /home/gamer/game
export DISPLAY=:0
export WINEPREFIX="/home/gamer/game/compatdata/pfx"
export WINEDEBUG="+module,+dll,+err,+warn"
/home/gamer/.steam/root/compatibilitytools.d/GE-Proton8-25/files/bin/wine /home/gamer/game/HMA.exe -skip_launcher > /tmp/wine_direct.log 2>&1
