#!/bin/bash
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1002
export STEAM_COMPAT_CLIENT_INSTALL_PATH=/home/gamer/.steam/root
export STEAM_COMPAT_DATA_PATH=/home/gamer/game/compatdata
export PROTON_USE_WINED3D=0
export DXVK_LOG_LEVEL=none
export WINEDEBUG=-all
# Forzar escritorio virtual — el juego renderiza en una ventana X11 capturable por Sunshine
export WINE_SIMULATE_WRITECOPY=1
export PROTON_FORCE_LARGE_ADDRESS_AWARE=1

mkdir -p /home/gamer/game/compatdata
mkdir -p /run/user/1002

PROTON=/home/gamer/.steam/root/compatibilitytools.d/GE-Proton8-25
WINE="$PROTON/files/bin/wine"
WINEPREFIX=/home/gamer/game/compatdata/pfx
WINESERVER="$PROTON/files/bin/wineserver"

# Usar explorer.exe /desktop para escritorio virtual 1920x1080
exec env \
    WINEPREFIX="$WINEPREFIX" \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_COMPAT_CLIENT_INSTALL_PATH" \
    STEAM_COMPAT_DATA_PATH="$STEAM_COMPAT_DATA_PATH" \
    /home/gamer/.steam/root/compatibilitytools.d/GE-Proton8-25/proton run \
    /home/gamer/game/HMA.exe
