#!/bin/bash
echo "**** Disabling SHM for PulseAudio and generic clients ****"
mkdir -p /etc/pulse
echo "enable-shm = no" >> /etc/pulse/daemon.conf
echo "enable-shm = no" >> /etc/pulse/client.conf
export PULSE_SERVER="unix:/tmp/pulseaudio.socket"
# Also instruct Chromium-based apps (like Steam CEF) to use less SHM if possible
# Steam CEF uses --disable-dev-shm-usage internally sometimes, but we can't force it globally via env var easily for everything,
# but disabling Xorg MIT-SHM and Pulse SHM is usually enough for 64MB /dev/shm.
echo "SHM fixes applied."
