FROM josh5/steam-headless:latest

ENV MODE=primary
ENV DEBIAN_FRONTEND=noninteractive

# Install Tailscale, Python3, and SSH Server
RUN curl -fsSL https://tailscale.com/install.sh | sh && \
    apt-get update && apt-get install -y openssh-server xserver-xorg-video-dummy && \
    mkdir -p /var/run/sshd && \
    echo 'root:playstone' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Start SSHD during init
RUN echo '#!/bin/bash' > /etc/cont-init.d/01-sshd.sh && \
    echo '/usr/sbin/sshd -D &' >> /etc/cont-init.d/01-sshd.sh && \
    chmod +x /etc/cont-init.d/01-sshd.sh

# Prevent 60-configure_gpu_driver.sh from crashing the container if NVIDIA driver download fails
RUN sed -i 's/return 1/return 0/g' /etc/cont-init.d/60-configure_gpu_driver.sh && \
    sed -i 's/exit 1/exit 0/g' /etc/cont-init.d/60-configure_gpu_driver.sh

# After 60-configure_gpu_driver.sh runs (which generates xorg.conf using the real nvidia-xconfig),
# this script ensures the Virtual resolution is injected into Section "Screen".
COPY agent/99-fix-xorg.sh /etc/cont-init.d/99-fix-xorg.sh
RUN chmod +x /etc/cont-init.d/99-fix-xorg.sh

# Prevent 80-configure_flatpak.sh from crashing the container when it tries to remount /proc unprivileged
RUN sed -i 's|mount -t proc none /proc|echo "Ignored unprivileged mount /proc"|g' /etc/cont-init.d/80-configure_flatpak.sh

RUN mkdir -p /home/default/init.d
COPY agent/vm_startup.sh /home/default/init.d/playstone_startup.sh
RUN chmod +x /home/default/init.d/playstone_startup.sh
