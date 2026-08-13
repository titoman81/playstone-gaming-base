#!/bin/bash
cd /home/gamer/steamless
echo "[STEAMLESS] Current directory: \$(pwd)"
echo "[STEAMLESS] Listing directory..."
ls -l
echo "[STEAMLESS] Running Steamless.CLI.exe..."
sudo -u gamer WINEPREFIX="/home/gamer/game/compatdata/pfx" DISPLAY=":0" /home/gamer/.steam/root/compatibilitytools.d/GE-Proton8-25/files/bin/wine Steamless.CLI.exe /home/gamer/game/HMA.exe
