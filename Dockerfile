FROM josh5/steam-headless:latest

ENV MODE=primary
ENV DEBIAN_FRONTEND=noninteractive

# Install Tailscale and Python3 (python3 is usually installed, but ensure it)
RUN curl -fsSL https://tailscale.com/install.sh | sh

# Prevent 60-configure_gpu_driver.sh from crashing the container if NVIDIA driver download fails
RUN sed -i 's/return 1/return 0/g' /etc/cont-init.d/60-configure_gpu_driver.sh && \
    sed -i 's/exit 1/exit 0/g' /etc/cont-init.d/60-configure_gpu_driver.sh

# After 60-configure_gpu_driver.sh runs (which generates xorg.conf using the real nvidia-xconfig),
# this script ensures the Virtual resolution is injected into Section "Screen".
RUN echo '#!/bin/bash' > /etc/cont-init.d/99-fix-xorg.sh && \
    echo 'if [ -f /etc/X11/xorg.conf ]; then' >> /etc/cont-init.d/99-fix-xorg.sh && \
    echo '    if ! grep -q "Virtual 1920 1080" /etc/X11/xorg.conf; then' >> /etc/cont-init.d/99-fix-xorg.sh && \
    echo '        awk '\''/Section "Screen"/{print;print "    SubSection \"Display\"\n        Depth 24\n        Virtual 1920 1080\n    EndSubSection";next}1'\'' /etc/X11/xorg.conf > /tmp/xorg.conf && mv /tmp/xorg.conf /etc/X11/xorg.conf' >> /etc/cont-init.d/99-fix-xorg.sh && \
    echo '    fi' >> /etc/cont-init.d/99-fix-xorg.sh && \
    echo 'fi' >> /etc/cont-init.d/99-fix-xorg.sh && \
    echo 'echo "capture = x11" >> /templates/sunshine/sunshine.conf' >> /etc/cont-init.d/99-fix-xorg.sh && \
    chmod +x /etc/cont-init.d/99-fix-xorg.sh

# Prevent 80-configure_flatpak.sh from crashing the container when it tries to remount /proc unprivileged
RUN sed -i 's|mount -t proc none /proc|echo "Ignored unprivileged mount /proc"|g' /etc/cont-init.d/80-configure_flatpak.sh

RUN mkdir -p /home/default/init.d
COPY agent/vm_startup.sh /home/default/init.d/playstone_startup.sh
RUN chmod +x /home/default/init.d/playstone_startup.sh
