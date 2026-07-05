FROM josh5/steam-headless:latest

ENV MODE=primary
ENV DEBIAN_FRONTEND=noninteractive

# Install Tailscale and Python3 (python3 is usually installed, but ensure it)
RUN curl -fsSL https://tailscale.com/install.sh | sh

# Prevent 60-configure_gpu_driver.sh from crashing the container if NVIDIA driver download fails
RUN sed -i 's/return 1/return 0/g' /etc/cont-init.d/60-configure_gpu_driver.sh && \
    sed -i 's/exit 1/exit 0/g' /etc/cont-init.d/60-configure_gpu_driver.sh

# Create a smart fake nvidia-xconfig in Python that parses arguments and generates a valid xorg.conf
RUN echo '#!/usr/bin/env python3' > /usr/bin/nvidia-xconfig && \
    echo 'import sys, argparse' >> /usr/bin/nvidia-xconfig && \
    echo 'parser = argparse.ArgumentParser()' >> /usr/bin/nvidia-xconfig && \
    echo 'parser.add_argument("--virtual")' >> /usr/bin/nvidia-xconfig && \
    echo 'parser.add_argument("--busid")' >> /usr/bin/nvidia-xconfig && \
    echo 'args, _ = parser.parse_known_args()' >> /usr/bin/nvidia-xconfig && \
    echo 'busid_str = f"    BusID          \"{args.busid}\"\\n" if args.busid else ""' >> /usr/bin/nvidia-xconfig && \
    echo 'virtual_str = f"        Virtual     {args.virtual.replace(\"x\", \" \")}\\n" if args.virtual else "        Virtual     1920 1080\\n"' >> /usr/bin/nvidia-xconfig && \
    echo 'conf = f"""Section "ServerLayout"' >> /usr/bin/nvidia-xconfig && \
    echo '    Identifier     "Layout0"' >> /usr/bin/nvidia-xconfig && \
    echo '    Screen      0  "Screen0" 0 0' >> /usr/bin/nvidia-xconfig && \
    echo 'EndSection' >> /usr/bin/nvidia-xconfig && \
    echo 'Section "Device"' >> /usr/bin/nvidia-xconfig && \
    echo '    Identifier     "Device0"' >> /usr/bin/nvidia-xconfig && \
    echo '    Driver         "nvidia"' >> /usr/bin/nvidia-xconfig && \
    echo '    VendorName     "NVIDIA Corporation"' >> /usr/bin/nvidia-xconfig && \
    echo '{busid_str}' >> /usr/bin/nvidia-xconfig && \
    echo '    Option         "AllowEmptyInitialConfiguration" "True"' >> /usr/bin/nvidia-xconfig && \
    echo 'EndSection' >> /usr/bin/nvidia-xconfig && \
    echo 'Section "Screen"' >> /usr/bin/nvidia-xconfig && \
    echo '    Identifier     "Screen0"' >> /usr/bin/nvidia-xconfig && \
    echo '    Device         "Device0"' >> /usr/bin/nvidia-xconfig && \
    echo '    DefaultDepth    24' >> /usr/bin/nvidia-xconfig && \
    echo '    Option         "AllowEmptyInitialConfiguration" "True"' >> /usr/bin/nvidia-xconfig && \
    echo '    SubSection     "Display"' >> /usr/bin/nvidia-xconfig && \
    echo '        Depth       24' >> /usr/bin/nvidia-xconfig && \
    echo '{virtual_str}' >> /usr/bin/nvidia-xconfig && \
    echo '    EndSubSection' >> /usr/bin/nvidia-xconfig && \
    echo 'EndSection"""' >> /usr/bin/nvidia-xconfig && \
    echo 'with open("/etc/X11/xorg.conf", "w") as f: f.write(conf)' >> /usr/bin/nvidia-xconfig && \
    chmod +x /usr/bin/nvidia-xconfig

# Prevent 80-configure_flatpak.sh from crashing the container when it tries to remount /proc unprivileged
RUN sed -i 's|mount -t proc none /proc|echo "Ignored unprivileged mount /proc"|g' /etc/cont-init.d/80-configure_flatpak.sh

RUN mkdir -p /home/default/init.d
COPY agent/vm_startup.sh /home/default/init.d/playstone_startup.sh
RUN chmod +x /home/default/init.d/playstone_startup.sh
