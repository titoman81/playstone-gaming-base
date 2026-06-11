FROM runpod/pytorch:2.1.0-py3.10-cuda11.8.0-devel-ubuntu22.04

# 1. Configurar entorno non-interactive
ENV DEBIAN_FRONTEND=noninteractive
ENV NEEDRESTART_MODE=a
ENV NEEDRESTART_SUSPEND=1

# 2. Agregar arquitectura i386 (necesaria para Steam)
RUN dpkg --add-architecture i386 && \
    apt-get update -y && \
    apt-get install -y software-properties-common && \
    add-apt-repository multiverse -y && \
    apt-get update -y

# 3. Aceptar licencias de Steam automáticamente
RUN echo "steam steam/license note ''" | debconf-set-selections && \
    echo "steam steam/question select I AGREE" | debconf-set-selections && \
    echo "steamcmd steam/license note ''" | debconf-set-selections && \
    echo "steamcmd steam/question select I AGREE" | debconf-set-selections

# 4. Instalar todas las dependencias pesadas de una sola vez
# Esto incluye utilidades, Xorg, Xvfb, Audio (PulseAudio), librerías de NVIDIA/Vulkan y Steam.
RUN apt-get install -y --no-install-recommends \
    steam:i386 \
    steamcmd \
    jq unzip curl wget sudo evtest dbus-x11 pciutils psmisc \
    xorg openbox xterm tar xz-utils mesa-utils vulkan-tools xvfb \
    libgl1-mesa-dri libgl1-mesa-glx libvulkan1 \
    pulseaudio pavucontrol libnss3 libgconf-2-4 libxss1 libasound2 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libgbm1 libnspr4 libpango-1.0-0 libxkbcommon0 libxcomposite1 libxdamage1 \
    libxfixes3 libxrandr2 libibus-1.0-5 libinput10 \
    nvidia-xconfig libnvidia-gl-535:i386 libvulkan1:i386 mesa-vulkan-drivers:i386 mesa-vulkan-drivers && \
    rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/games/steamcmd /usr/bin/steamcmd || true

# 5. Instalar Sunshine (Servidor de Streaming)
RUN wget -qO /tmp/sunshine.deb https://github.com/LizardByte/Sunshine/releases/download/v0.22.2/sunshine-ubuntu-22.04-amd64.deb && \
    mv /bin/udevadm /bin/udevadm.bak || true && \
    ln -s /bin/true /bin/udevadm && \
    apt-get update && apt-get install -y /tmp/sunshine.deb && \
    rm /bin/udevadm && \
    mv /bin/udevadm.bak /bin/udevadm || true && \
    rm -f /tmp/sunshine.deb && \
    rm -rf /var/lib/apt/lists/*

# 6. Instalar Tailscale (para redes privadas virtuales)
RUN curl -fsSL https://tailscale.com/install.sh | sh

# 7. Crear el usuario "gamer" y asignarle permisos de video/audio
RUN useradd -m -s /bin/bash gamer && \
    usermod -aG input,video,audio,render gamer && \
    mkdir -p /home/gamer/game && \
    chown -R gamer:gamer /home/gamer/game

# 8. Entrypoint de RunPod por defecto
# La imagen base de runpod arranca Jupyter y SSH. Tu orquestador seguirá
# usando paramiko para conectarse por SSH e inyectar el script vm_startup.sh,
# la diferencia es que ahora el script se ejecutará en segundos porque
# ya no tiene que descargar ningún paquete.
CMD ["/start.sh"]
