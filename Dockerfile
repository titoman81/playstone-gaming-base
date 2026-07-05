FROM josh5/steam-headless:latest

ENV DEBIAN_FRONTEND=noninteractive

# Install curl, Tailscale and nvidia-xconfig (needed for 70-configure_xorg.sh on RunPod)
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends curl software-properties-common wget && \
    wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && \
    apt-get update -y && \
    apt-get install -y --no-install-recommends nvidia-xconfig && \
    curl -fsSL https://tailscale.com/install.sh | sh && \
    rm -rf /var/lib/apt/lists/*

# Prevent 60-configure_gpu_driver.sh from crashing the container if NVIDIA driver download fails
RUN sed -i 's/return 1/return 0/g' /etc/cont-init.d/60-configure_gpu_driver.sh && \
    sed -i 's/exit 1/exit 0/g' /etc/cont-init.d/60-configure_gpu_driver.sh

RUN mkdir -p /home/default/init.d
COPY agent/vm_startup.sh /home/default/init.d/playstone_startup.sh
RUN chmod +x /home/default/init.d/playstone_startup.sh
