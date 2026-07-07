FROM josh5/steam-headless:latest

ENV MODE=primary
ENV DEBIAN_FRONTEND=noninteractive

# Install Tailscale, Python3, and SSH Server
RUN curl -fsSL https://tailscale.com/install.sh | sh && \
    apt-get update && apt-get install -y openssh-server xserver-xorg-video-dummy && \
    mkdir -p /var/run/sshd && \
    echo 'root:playstone' | chpasswd && \
    sed -i 's/#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    echo 'StrictModes no' >> /etc/ssh/sshd_config

# Start SSHD during init - use fork mode (no -D) so it daemonizes properly
RUN echo '#!/bin/bash' > /etc/cont-init.d/01-sshd.sh && \
    echo 'mkdir -p /var/run/sshd' >> /etc/cont-init.d/01-sshd.sh && \
    echo '/usr/sbin/sshd' >> /etc/cont-init.d/01-sshd.sh && \
    echo 'echo "[SSHD] Started on port 22"' >> /etc/cont-init.d/01-sshd.sh && \
    chmod +x /etc/cont-init.d/01-sshd.sh

# Prevent 60-configure_gpu_driver.sh from crashing the container by completely removing it.
# RunPod already provides the NVIDIA drivers via the host, so we don't need this script to run the .run installer.
RUN rm -f /etc/cont-init.d/60-configure_gpu_driver.sh

# After 60-configure_gpu_driver.sh runs (which generates xorg.conf using the real nvidia-xconfig),
# this script ensures the Virtual resolution is injected into Section "Screen".
COPY agent/99-fix-xorg.sh /etc/cont-init.d/99-fix-xorg.sh
RUN chmod +x /etc/cont-init.d/99-fix-xorg.sh

# Prevent 80-configure_flatpak.sh from crashing the container when it tries to remount /proc unprivileged
RUN sed -i 's|mount -t proc none /proc|echo "Ignored unprivileged mount /proc"|g' /etc/cont-init.d/80-configure_flatpak.sh

RUN mkdir -p /home/default/init.d
COPY agent/vm_startup.sh /home/default/init.d/playstone_startup.sh
RUN chmod +x /home/default/init.d/playstone_startup.sh
