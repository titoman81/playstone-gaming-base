#!/bin/bash
echo "**** Configure Xorg with NVIDIA BusID ****"

# Obtener BusID desde nvidia-smi para evitar fallos de auto-detección en Xorg
raw_bus=$(nvidia-smi --format=csv,noheader --query-gpu=pci.bus_id 2>/dev/null | head -n1)
bus_id=""

if [ -n "$raw_bus" ] && [ "$raw_bus" != "[Not Supported]" ]; then
    bus_hex=$(echo "$raw_bus" | awk -F: '{print $2}')
    if [ -n "$bus_hex" ]; then
        bus_dec=$(printf '%d' "0x${bus_hex}" 2>/dev/null)
        if [ -n "$bus_dec" ]; then
            dev=$(echo "$raw_bus" | awk -F: '{print $3}' | cut -d'.' -f1)
            func=$(echo "$raw_bus" | awk -F: '{print $3}' | cut -d'.' -f2)
            bus_id="PCI:${bus_dec}:${dev}:${func}"
        fi
    fi
fi

if [ -z "$bus_id" ]; then
    echo "WARNING: Could not parse NVIDIA BusID. Using default PCI:2:0:0."
    bus_id="PCI:2:0:0"
else
    echo "Extracted NVIDIA BusID: $bus_id"
fi

# Use printf to avoid heredoc quoting issues in container init environments
XORG_CONF="/etc/X11/xorg.conf"

printf 'Section "Device"\n' > "$XORG_CONF"
printf '    Identifier  "Configured Video Device"\n' >> "$XORG_CONF"
printf '    Driver      "dummy"\n' >> "$XORG_CONF"
printf '    VideoRam    256000\n' >> "$XORG_CONF"
printf 'EndSection\n\n' >> "$XORG_CONF"

printf 'Section "Monitor"\n' >> "$XORG_CONF"
printf '    Identifier  "Configured Monitor"\n' >> "$XORG_CONF"
printf '    HorizSync   31.5 - 133.0\n' >> "$XORG_CONF"
printf '    VertRefresh 50.0 - 120.0\n' >> "$XORG_CONF"
printf 'EndSection\n\n' >> "$XORG_CONF"

printf 'Section "Screen"\n' >> "$XORG_CONF"
printf '    Identifier  "Default Screen"\n' >> "$XORG_CONF"
printf '    Monitor     "Configured Monitor"\n' >> "$XORG_CONF"
printf '    Device      "Configured Video Device"\n' >> "$XORG_CONF"
printf '    DefaultDepth 24\n' >> "$XORG_CONF"
printf '    SubSection "Display"\n' >> "$XORG_CONF"
printf '        Depth 24\n' >> "$XORG_CONF"
printf '        Modes "1920x1080"\n' >> "$XORG_CONF"
printf '    EndSubSection\n' >> "$XORG_CONF"

echo "Xorg config written to $XORG_CONF:"
cat "$XORG_CONF"

# ENABLE XORG IN SUPERVISORD
# The base image has autostart=false for xorg by default. It relied on the original script
# to enable it if a GPU was found. Since we replaced the script, we must enable it manually.
if [ -f /etc/supervisor.d/xorg.ini ]; then
    sed -i 's|^autostart.*=.*false|autostart=true|' /etc/supervisor.d/xorg.ini
fi
