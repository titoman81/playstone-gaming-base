#!/bin/bash
if [ -f /etc/X11/xorg.conf ]; then
    if ! grep -q "Virtual 1920 1080" /etc/X11/xorg.conf; then
        echo "Inyectando resolución virtual y driver dummy en xorg.conf..."
        awk '/Section "Screen"/{print;print "    SubSection \"Display\"\n        Depth 24\n        Virtual 1920 1080\n    EndSubSection";next}1' /etc/X11/xorg.conf > /tmp/xorg.conf && mv /tmp/xorg.conf /etc/X11/xorg.conf
        sed -i 's/Driver         "nvidia"/Driver         "dummy"/g' /etc/X11/xorg.conf
    fi
fi
echo "capture = x11" >> /templates/sunshine/sunshine.conf
