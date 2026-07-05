FROM josh5/steam-headless:latest

# ── Configurar entorno non-interactive ───────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive

# ── Instalar Tailscale ───────────────────────────────────────────────────────
# curl ya viene en la imagen base; solo necesitamos el instalador de Tailscale.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends curl && \
    curl -fsSL https://tailscale.com/install.sh | sh && \
    rm -rf /var/lib/apt/lists/*

# ── Script de arranque de Playstone ─────────────────────────────────────────
# Steam-Headless ejecuta automáticamente cualquier *.sh dentro de ~/init.d/
# (/home/default/init.d/) durante el arranque del contenedor, DESPUÉS de que
# Xorg, Steam y Sunshine ya estén listos. Esto es el mecanismo oficial.
# Ver: https://github.com/Steam-Headless/docker-steam-headless#additional-software
RUN mkdir -p /home/default/init.d
COPY agent/vm_startup.sh /home/default/init.d/playstone_startup.sh
RUN chmod +x /home/default/init.d/playstone_startup.sh
