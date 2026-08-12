#!/bin/bash
# 70-configure_xorg.sh (override)
# Generates xorg.conf for NVIDIA Headless without manual BusID parsing

# Removed set -e so failures don't crash the entire s6-overlay container
echo "  - Generating generic NVIDIA headless xorg.conf..."

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
        Virtual     ${DISPLAY_SIZEW} ${DISPLAY_SIZEH}
    EndSubSection
EndSection
EOF

echo "  - xorg.conf written successfully."
cat /etc/X11/xorg.conf

# CRITICAL: Tell supervisor to actually start Xorg!
echo "  - Enabling Xorg in supervisor..."
sed -i 's/autostart=false/autostart=true/g' /etc/supervisor.d/xorg.ini
