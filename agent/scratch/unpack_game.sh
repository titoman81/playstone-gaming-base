#!/bin/bash
set -e

echo "[UNPACK] Starting SteamStub DRM stripping process..."

# 1. Download Steamless
STEAMLESS_URL="https://github.com/atom0s/Steamless/releases/download/v3.1.0.5/Steamless.v3.1.0.5.-.by.atom0s.zip"
echo "[UNPACK] Downloading Steamless from ${STEAMLESS_URL}..."
curl -L -o /tmp/steamless.zip "${STEAMLESS_URL}"

# 2. Unzip Steamless into gamer's home directory
echo "[UNPACK] Unzipping Steamless to /home/gamer/steamless..."
mkdir -p /home/gamer/steamless
unzip -o /tmp/steamless.zip -d /home/gamer/steamless

# Copy Steamless.API.dll from Plugins to root folder so Wine Mono can load it
echo "[UNPACK] Copying Steamless.API.dll to root folder..."
cp /home/gamer/steamless/Plugins/Steamless.API.dll /home/gamer/steamless/

# 3. Locate GE-Proton8-25 Wine
PROTON_DIR="/home/gamer/.steam/root/compatibilitytools.d/GE-Proton8-25"
WINE_BIN="${PROTON_DIR}/files/bin/wine"
WINEPREFIX="/home/gamer/game/compatdata/pfx"

if [ ! -f "${WINE_BIN}" ]; then
    echo "[ERROR] GE-Proton8-25 wine executable not found at ${WINE_BIN}"
    exit 1
fi

echo "[UNPACK] Using Wine from: ${WINE_BIN}"
echo "[UNPACK] Using WINEPREFIX: ${WINEPREFIX}"

# 4. Check if HMA.exe is already backed up
GAME_DIR="/home/gamer/game"
if [ ! -f "${GAME_DIR}/HMA.exe" ]; then
    echo "[ERROR] HMA.exe not found in ${GAME_DIR}"
    exit 1
fi

# Ensure correct ownership and permissions for /home/gamer/steamless
sudo chown -R gamer:gamer /home/gamer/steamless
sudo chown -R gamer:gamer "${GAME_DIR}"

# 5. Run Steamless.CLI.exe from its own directory under the gamer user
echo "[UNPACK] Running Steamless.CLI.exe..."
export WINEPREFIX="${WINEPREFIX}"
export DISPLAY=":0"

# Change directory to /home/gamer/steamless and run under sudo -u gamer
cd /home/gamer/steamless
sudo -u gamer bash -c "cd /home/gamer/steamless && WINEPREFIX='${WINEPREFIX}' DISPLAY=':0' '${WINE_BIN}' Steamless.CLI.exe '${GAME_DIR}/HMA.exe'"

# 6. Check output
echo "[UNPACK] Checking output files in ${GAME_DIR}..."
ls -lh "${GAME_DIR}" | grep -i HMA

echo "[UNPACK] Done!"
