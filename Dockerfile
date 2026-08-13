FROM josh5/steam-headless:latest

ENV MODE=primary
ENV DEBIAN_FRONTEND=noninteractive

# Install Tailscale and SSH Server
RUN curl -fsSL https://tailscale.com/install.sh | sh && \
    apt-get update && apt-get install -y openssh-server xserver-xorg-video-dummy && \
    mkdir -p /var/run/sshd && \
    echo 'root:playstone' | chpasswd && \
    sed -i 's/#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    echo 'StrictModes no' >> /etc/ssh/sshd_config

# ── Replace Sunshine with v0.21.0 ────────────────────────────────────────────
# REASON: Sunshine >= 2024.x switched from XTest (X11-based) to inputtino
# (kernel uinput-based) for mouse/keyboard injection. RunPod Community Cloud
# does NOT expose /dev/uinput to containers (cgroup restriction), so the
# modern Sunshine cannot inject any input at all.
#
# Sunshine v0.21.0 uses libXtst/XTest which works purely via X11 - no kernel
# device needed. This is the last version with reliable XTest input on Linux.
RUN apt-get update && \
    apt-get install -y libxtst6 libxrandr2 libxfixes3 libevdev2 || true && \
    SUNSHINE_DEB_URL="https://github.com/LizardByte/Sunshine/releases/download/v0.21.0/sunshine-ubuntu-22.04-amd64.deb" && \
    curl -L -o /tmp/sunshine-0.21.0.deb "$SUNSHINE_DEB_URL" && \
    dpkg -i /tmp/sunshine-0.21.0.deb || apt-get install -f -y && \
    rm -f /tmp/sunshine-0.21.0.deb && \
    echo "[Dockerfile] Sunshine version installed:" && \
    (sunshine --version 2>/dev/null || /usr/bin/sunshine --version 2>/dev/null || echo "sunshine binary ready")

# Start SSHD during init - use fork mode (no -D) so it daemonizes properly
RUN echo '#!/bin/bash' > /etc/cont-init.d/01-sshd.sh && \
    echo 'mkdir -p /var/run/sshd' >> /etc/cont-init.d/01-sshd.sh && \
    echo '/usr/sbin/sshd' >> /etc/cont-init.d/01-sshd.sh && \
    echo 'echo "[SSHD] Started on port 22"' >> /etc/cont-init.d/01-sshd.sh && \
    chmod +x /etc/cont-init.d/01-sshd.sh

# Remove the GPU driver installer script - RunPod provides drivers via the host.
RUN rm -f /etc/cont-init.d/60-configure_gpu_driver.sh

# Override 70-configure_xorg.sh: the base image calls nvidia-xconfig with flags
# (--no-multigpu etc.) that don't exist in older package versions. Our version
# generates xorg.conf directly from nvidia-smi output - no nvidia-xconfig needed.
COPY agent/70-configure_xorg.sh /etc/cont-init.d/70-configure_xorg.sh
RUN chmod +x /etc/cont-init.d/70-configure_xorg.sh

# Prevent 80-configure_flatpak.sh from crashing the container when it tries to remount /proc unprivileged
RUN sed -i 's|mount -t proc none /proc|echo "Ignored unprivileged mount /proc"|g' /etc/cont-init.d/80-configure_flatpak.sh

# Fix 1: Create /dev/uinput at startup so Sunshine can inject virtual mouse/keyboard events.
# RunPod Secure Cloud does not expose this device by default. This script reads the
# major:minor from /sys/class/misc/uinput and tries cgroup allow + mknod.
COPY agent/25-fix-uinput.sh /etc/cont-init.d/25-fix-uinput.sh
RUN chmod +x /etc/cont-init.d/25-fix-uinput.sh

# Fix 2: Pre-accept Steam EULA and enable Steam in supervisord.
# The base image's steam supervisor program has autostart=false and the installer
# shows a zenity GUI dialog for EULA acceptance — both invisible in headless mode.
COPY agent/91-configure-steam.sh /etc/cont-init.d/91-configure-steam.sh
RUN chmod +x /etc/cont-init.d/91-configure-steam.sh

RUN mkdir -p /home/default/init.d
COPY agent/vm_startup.sh /home/default/init.d/playstone_startup.sh
RUN chmod +x /home/default/init.d/playstone_startup.sh
