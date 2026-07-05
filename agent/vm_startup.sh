#!/bin/bash

# ════════════════════════════════════════════════════════════════════════════════
# Playstone Cloud Gaming - Startup Script v4.0 (Steam-Headless Edition)
# ════════════════════════════════════════════════════════════════════════════════
# MECANISMO: Este script vive en ~/init.d/ y es ejecutado AUTOMÁTICAMENTE
# por el entrypoint de josh5/steam-headless, DESPUÉS de que supervisor
#
# haya arrancado Steam, Sunshine y Xorg. NO requiere sleep infinity al
# final: los scripts de ~/init.d/ se ejecutan en background por diseño.
#
# Responsabilidades de este script:
#   1. Conectar Tailscale (si hay authkey)
#   2. Esperar a que Sunshine esté listo
#   3. Reportar estado a Supabase
# ════════════════════════════════════════════════════════════════════════════════

# ── Idempotency ────────────────────────────────────────────────────────────────────────────
# Usamos /tmp/ en lugar de /var/run/ porque el usuario 'default' (no root)
# puede no tener permisos de escritura en /var/run/
PIDFILE="/tmp/playstone_startup.pid"
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[INIT] Instancia previa (PID $OLD_PID) activa. Terminándola..."
        kill -9 "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
fi
echo $$ > "$PIDFILE"

echo "[$(date)] ═══ Playstone Cloud Gaming v4.0 (Steam-Headless) ═══"

# Background wrapper to prevent blocking entrypoint.sh
(

# ── Helper: Reportar estado a Supabase ──────────────────────────────────────
report_status() {
    local msg="$1"
    local status="${2:-provisioning}"
    echo "[STATUS] $msg"
    if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_KEY" ] && [ -n "$SESSION_ID" ]; then
        curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
             -H "apikey: ${SUPABASE_KEY}" \
             -H "Authorization: Bearer ${SUPABASE_KEY}" \
             -H "Content-Type: application/json" \
             -d "{\"status_message\": \"$msg\", \"status\": \"$status\"}" \
             > /dev/null 2>&1 || true
    fi
}

report_status "Servidor arrancando (Steam-Headless)..." "provisioning"

# ── FASE 1: Tailscale ────────────────────────────────────────────────────────
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo "[INIT] Conectando Tailscale..."
    report_status "Conectando a red privada Tailscale..." "provisioning"

    # Arrancar tailscaled en modo userspace (no requiere /dev/net/tun en Docker)
    mkdir -p ~/.tailscale
    tailscaled --tun=userspace-networking \
               --socks5-server=localhost:1055 \
               --outbound-http-proxy-listen=localhost:1055 \
               --socket=~/.tailscale/tailscaled.sock \
               > ~/.tailscale/tailscaled.log 2>&1 &
    sleep 5

    tailscale --socket=~/.tailscale/tailscaled.sock up \
        --authkey="$TAILSCALE_AUTHKEY" \
        --hostname="playstone-${SESSION_ID:0:6}" \
        --accept-routes \
        --reset
    sleep 3

    TS_IP=$(tailscale --socket=~/.tailscale/tailscaled.sock ip -4 2>/dev/null || echo "")
    if [ -n "$TS_IP" ]; then
        echo "[OK] Tailscale conectado. IP: $TS_IP"
        curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
             -H "apikey: ${SUPABASE_KEY}" \
             -H "Authorization: Bearer ${SUPABASE_KEY}" \
             -H "Content-Type: application/json" \
             -d "{\"tailscale_ip\": \"$TS_IP\"}" \
             > /dev/null 2>&1 || true
    else
        echo "[WARN] Tailscale no obtuvo IP."
    fi
else
    echo "[INFO] TAILSCALE_AUTHKEY no provisto. Saltando Tailscale."
fi

# ── FASE 2: Esperar a que Sunshine esté listo ────────────────────────────────
# josh5/steam-headless arranca Sunshine automáticamente.
# Esperamos hasta 3 minutos a que responda en el puerto 47990.
echo "[INIT] Esperando a que Sunshine esté disponible (puerto 47990)..."
report_status "Iniciando servicios de streaming..." "provisioning"

SUNSHINE_READY=0
for i in $(seq 1 36); do
    if curl -sk --max-time 3 "https://localhost:47990" > /dev/null 2>&1; then
        SUNSHINE_READY=1
        echo "[OK] Sunshine listo después de $((i * 5)) segundos."
        break
    fi
    echo "[*] Esperando Sunshine... ($((i * 5))s)"
    sleep 5
done

if [ "$SUNSHINE_READY" -eq 0 ]; then
    echo "[ERROR] Sunshine no respondió tras 3 minutos."
    report_status "Error: Sunshine no pudo iniciarse." "failed"
    exit 1
fi

# ── FASE 3: Reportar listo ───────────────────────────────────────────────────────────────────────
echo "[OK] ✓ Servidor Playstone listo. Steam y Sunshine corriendo."
report_status "Servidor listo. Conecta con Moonlight." "ready"

) > /home/default/playstone_background.log 2>&1 &

