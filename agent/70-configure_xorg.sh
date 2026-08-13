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

printf 'Section "ServerLayout"\n' > "$XORG_CONF"
printf '    Identifier     "Layout0"\n' >> "$XORG_CONF"
printf '    Screen      0  "Screen0"\n' >> "$XORG_CONF"
printf 'EndSection\n\n' >> "$XORG_CONF"

printf 'Section "Device"\n' >> "$XORG_CONF"
printf '    Identifier     "Device0"\n' >> "$XORG_CONF"
printf '    Driver         "nvidia"\n' >> "$XORG_CONF"
printf '    VendorName     "NVIDIA Corporation"\n' >> "$XORG_CONF"
printf '    BusID          "%s"\n' "$bus_id" >> "$XORG_CONF"
printf '    Option         "AllowEmptyInitialConfiguration" "True"\n' >> "$XORG_CONF"
printf '    Option         "NoLogo" "true"\n' >> "$XORG_CONF"
printf 'EndSection\n\n' >> "$XORG_CONF"

printf 'Section "Monitor"\n' >> "$XORG_CONF"
printf '    Identifier     "Monitor0"\n' >> "$XORG_CONF"
printf '    VendorName     "Unknown"\n' >> "$XORG_CONF"
printf '    ModelName      "Unknown"\n' >> "$XORG_CONF"
printf '    Option         "DPMS"\n' >> "$XORG_CONF"
printf 'EndSection\n\n' >> "$XORG_CONF"

printf 'Section "Screen"\n' >> "$XORG_CONF"
printf '    Identifier     "Screen0"\n' >> "$XORG_CONF"
printf '    Device         "Device0"\n' >> "$XORG_CONF"
printf '    Monitor        "Monitor0"\n' >> "$XORG_CONF"
printf '    DefaultDepth    24\n' >> "$XORG_CONF"
printf '    SubSection "Display"\n' >> "$XORG_CONF"
printf '        Depth       24\n' >> "$XORG_CONF"
printf '        Virtual     1920 1080\n' >> "$XORG_CONF"
printf '    EndSubSection\n' >> "$XORG_CONF"
printf 'EndSection\n' >> "$XORG_CONF"

echo "Xorg config written to $XORG_CONF:"
cat "$XORG_CONF"
