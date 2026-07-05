FROM josh5/steam-headless:latest

ENV DEBIAN_FRONTEND=noninteractive

# Install Tailscale (curl is already installed in the base image)
RUN curl -fsSL https://tailscale.com/install.sh | sh

# Prevent 60-configure_gpu_driver.sh from crashing the container if NVIDIA driver download fails
RUN sed -i 's/return 1/return 0/g' /etc/cont-init.d/60-configure_gpu_driver.sh && \
    sed -i 's/exit 1/exit 0/g' /etc/cont-init.d/60-configure_gpu_driver.sh

# Create a fake nvidia-xconfig to satisfy 70-configure_xorg.sh since RunPod doesn't provide it
RUN echo '#!/bin/bash' > /usr/bin/nvidia-xconfig && \
    echo 'cat << "EOF" > /etc/X11/xorg.conf' >> /usr/bin/nvidia-xconfig && \
    echo 'Section "Device"' >> /usr/bin/nvidia-xconfig && \
    echo '    Identifier     "Device0"' >> /usr/bin/nvidia-xconfig && \
    echo '    Driver         "nvidia"' >> /usr/bin/nvidia-xconfig && \
    echo '    VendorName     "NVIDIA Corporation"' >> /usr/bin/nvidia-xconfig && \
    echo 'EndSection' >> /usr/bin/nvidia-xconfig && \
    echo 'Section "Screen"' >> /usr/bin/nvidia-xconfig && \
    echo '    Identifier     "Screen0"' >> /usr/bin/nvidia-xconfig && \
    echo '    Device         "Device0"' >> /usr/bin/nvidia-xconfig && \
    echo '    DefaultDepth    24' >> /usr/bin/nvidia-xconfig && \
    echo 'EndSection' >> /usr/bin/nvidia-xconfig && \
    echo 'EOF' >> /usr/bin/nvidia-xconfig && \
    chmod +x /usr/bin/nvidia-xconfig

# Prevent 80-configure_flatpak.sh from crashing the container when it tries to remount /proc unprivileged
RUN sed -i 's|mount -t proc none /proc|echo "Ignored unprivileged mount /proc"|g' /etc/cont-init.d/80-configure_flatpak.sh

RUN mkdir -p /home/default/init.d
COPY agent/vm_startup.sh /home/default/init.d/playstone_startup.sh
RUN chmod +x /home/default/init.d/playstone_startup.sh
