#!/bin/bash
###
# 91-configure-steam.sh
# Playstone Gaming - Pre-accept Steam EULA and activate Steam via supervisord
#
# WHY THIS IS NEEDED:
#   The base image (josh5/steam-headless) uses the Debian package 'steam-installer'
#   which is just a wrapper. When it runs, it launches 'zenity' to show a GUI dialog
#   asking the user to accept the Steam EULA. In a headless/cloud environment this
#   dialog is invisible and blocks the installation forever.
#
#   This script:
#   1. Pre-accepts the EULA via debconf so the zenity dialog never appears
#   2. Creates the eula_accepted marker file that Steam checks
#   3. Enables the steam supervisor program (it's autostart=false by default)
#   4. Kills any stuck zenity/steam processes from previous attempts
###

set -e

print_header() { echo -e "\e[35m**** ${*} ****\e[0m"; }
print_step()   { echo -e "\e[36m  - ${*}\e[0m"; }
print_ok()     { echo -e "\e[32m  [OK] ${*}\e[0m"; }

print_header "Configure Steam (pre-accept EULA, enable supervisor)"

USER_HOME="/home/default"

# 1. Pre-accept Steam EULA via debconf (prevents zenity popup)
print_step "Pre-accepting Steam EULA via debconf..."
echo "steam steam/question select I AGREE" | debconf-set-selections 2>/dev/null || true
echo "steam steam/license note ''" | debconf-set-selections 2>/dev/null || true

# 2. Create the marker file Steam checks to skip the EULA screen
print_step "Creating Steam EULA accepted marker..."
mkdir -p "${USER_HOME}/.steam"
touch "${USER_HOME}/.steam/steam.eula_accepted"
chown -R default:default "${USER_HOME}/.steam" 2>/dev/null || true

# 3. Kill any stuck zenity processes (from previous failed installs on volume reuse)
if pgrep -x zenity > /dev/null 2>&1; then
    print_step "Killing stuck zenity processes..."
    killall -9 zenity 2>/dev/null || true
fi

# 4. Enable Steam in supervisord (base image has autostart=false by default)
#    We check if ENABLE_STEAM env var is set (from orchestrator) before enabling
if [[ "${ENABLE_STEAM:-true}" == "true" ]]; then
    STEAM_INI="/etc/supervisor.d/steam.ini"
    if [[ -f "${STEAM_INI}" ]]; then
        print_step "Enabling Steam in supervisord..."
        sed -i 's|^autostart.*=.*false|autostart=true|' "${STEAM_INI}"
        print_ok "Steam supervisord program enabled."
    else
        print_ok "No steam.ini found — Steam may start via another mechanism."
    fi
fi

print_ok "Steam configuration complete."
echo -e "\e[34mDONE\e[0m"
