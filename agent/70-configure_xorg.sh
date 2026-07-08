#!/bin/bash
# 70-configure_xorg.sh (override)
# Generates xorg.conf directly from nvidia-smi without nvidia-xconfig

set -e

# Get GPU info from nvidia-smi
if [ "${NVIDIA_VISIBLE_DEVICES:-}" == "all" ] || [ -z "${NVIDIA_VISIBLE_DEVICES:-}" ]; then
    gpu_select=$(nvidia-smi --format=csv,noheader --query-gpu=uuid 2>/dev/null | head -n1)
else
    gpu_select=$(nvidia-smi --format=csv,noheader --id=$(echo "$NVIDIA_VISIBLE_DEVICES" | cut -d ',' -f1) --query-gpu=uuid 2>/dev/null | head -n1)
fi

# Convert PCI bus ID: "00000000:0D:00.0" -> "PCI:13:0:0"
raw_bus=$(nvidia-smi --format=csv,noheader --query-gpu=pci.bus_id --id="${gpu_select}" 2>/dev/null | head -n1)
# Extract the "0D:00.0" part, convert hex bus to decimal
bus_hex=$(echo "$raw_bus" | awk -F: '{print $2}')
bus_dec=$(printf "%d" "0x${bus_hex}")
dev=$(echo "$raw_bus" | awk -F: '{print $3}' | cut -d'.' -f1)
func=$(echo "$raw_bus" | awk -F: '{print $3}' | cut -d'.' -f2)
bus_id="PCI:${bus_dec}:${dev}:${func}"

echo "  - Configuring X11 with GPU ID: '${gpu_select}'"
echo "  - Configuring X11 with PCI bus ID: '${bus_id}'"

DISPLAY_SIZEW="${DISPLAY_SIZEW:-1920}"
DISPLAY_SIZEH="${DISPLAY_SIZEH:-1080}"

mkdir -p /etc/X11
cat > /etc/X11/xorg.conf << EOF
Section "ServerLayout"
    Identifier     "Layout0"
    Screen      0  "Screen0"
EndSection

Section "Device"
    Identifier     "Device0"
    Driver         "nvidia"
    VendorName     "NVIDIA Corporation"
    BusID          "${bus_id}"
    Option         "AllowEmptyInitialConfiguration"
    Option         "NoLogo" "true"
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
        Virtual     ${DISPLAY_SIZEW} ${DISPLAY_SIZEH}
    EndSubSection
EndSection
EOF

echo "  - xorg.conf written successfully (no nvidia-xconfig needed)"
cat /etc/X11/xorg.conf
