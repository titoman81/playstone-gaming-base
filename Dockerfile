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
# El script solo configura Tailscale y reporta estado a Supabase.
# Steam, Sunshine y Xorg arrancan automáticamente mediante el entrypoint
# de la imagen base josh5/steam-headless.
COPY agent/vm_startup.sh /playstone_startup.sh
RUN chmod +x /playstone_startup.sh
