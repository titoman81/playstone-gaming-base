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
    echo "WARNING: Could not parse NVIDIA BusID. Xorg may fail to detect the GPU."
else
    echo "Extracted NVIDIA BusID: $bus_id"
fi

cat > /etc/X11/xorg.conf << EOF
Section "ServerLayout"
    Identifier     "Layout0"
    Screen      0  "Screen0"
EndSection

Section "Device"
    Identifier     "Device0"
    Driver         "nvidia"
    VendorName     "NVIDIA Corporation"
EOF

if [ -n "$bus_id" ]; then
    echo "    BusID          \"${bus_id}\"" >> /etc/X11/xorg.conf
fi

cat >> /etc/X11/xorg.conf << EOF
    Option         "AllowEmptyInitialConfiguration"
    Option         "NoLogo" "true"
    Option         "UseDisplayDevice" "None"
    Option         "ConnectedMonitor" "DFP-0"
EndSection

Section "Monitor"
    Identifier     "Monitor0"
    VendorName     "Unknown"
    ModelName      "Unknown"
    Option         "DPMS"
EndSection

Section "Screen"
    Identifier     "Screen0"
    Device         "Device0"
    Monitor        "Monitor0"
    DefaultDepth    24
    SubSection "Display"
        Depth       24
        Virtual     1920 1080
    EndSubSection
EndSection
EOF
