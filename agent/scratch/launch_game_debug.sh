#!/bin/bash
cd /home/gamer/game
export DISPLAY=:0
export STEAM_COMPAT_CLIENT_INSTALL_PATH="/home/gamer/.steam/root"
export STEAM_COMPAT_DATA_PATH="/home/gamer/game/compatdata"
export STEAM_COMPAT_APP_ID=203140
export PROTON_LOG=1
export PROTON_LOG_DIR=/tmp
export DXVK_HUD=fps
/home/gamer/.steam/root/compatibilitytools.d/GE-Proton8-25/proton run /home/gamer/game/HMA.exe -skip_launcher
