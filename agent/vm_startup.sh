#!/bin/bash

# ════════════════════════════════════════════════════════════════════════════════
# Playstone Cloud Gaming - Startup Script v4.0 (Steam-Headless Edition)
# ════════════════════════════════════════════════════════════════════════════════

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

(
report_status() {
    local msg="$1"
    local status="${2:-provisioning}"
    local errmsg="$3"
    echo "[STATUS] $msg"
    if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_KEY" ] && [ -n "$SESSION_ID" ]; then
        if [ -n "$errmsg" ]; then
            # Escape error message for JSON
            errmsg=$(echo "$errmsg" | jq -Rsa .)
            curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
                 -H "apikey: ${SUPABASE_KEY}" \
                 -H "Authorization: Bearer ${SUPABASE_KEY}" \
                 -H "Content-Type: application/json" \
                 -d "{\"status_message\": \"$msg\", \"status\": \"$status\", \"error_message\": $errmsg}" > /dev/null 2>&1 || true
        else
            curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
                 -H "apikey: ${SUPABASE_KEY}" \
                 -H "Authorization: Bearer ${SUPABASE_KEY}" \
                 -H "Content-Type: application/json" \
                 -d "{\"status_message\": \"$msg\", \"status\": \"$status\"}" > /dev/null 2>&1 || true
        fi
    fi
}

report_status "Servidor arrancando (Steam-Headless)..." "provisioning"

if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo "[INIT] Conectando Tailscale..."
    report_status "Conectando a red privada Tailscale..." "provisioning"

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
             -d "{\"tailscale_ip\": \"$TS_IP\"}" > /dev/null 2>&1 || true
    fi
fi

echo "[INIT] Esperando a que Sunshine esté disponible (puerto 47990)..."
report_status "Iniciando servicios de streaming..." "provisioning"

SUNSHINE_READY=0
for i in $(seq 1 36); do
    if curl -sk --max-time 3 "https://localhost:47990" > /dev/null 2>&1; then
        SUNSHINE_READY=1
        break
    fi
    sleep 5
done

if [ "$SUNSHINE_READY" -eq 0 ]; then
    echo "[ERROR] Sunshine no respondió tras 3 minutos."
    
    # Recolectar logs críticos para depuración
    DEBUG_LOG="=== XORG CONF ===\n$(cat /etc/X11/xorg.conf 2>/dev/null | head -n 50)\n"
    DEBUG_LOG="$DEBUG_LOG\n=== XORG ERRORS ===\n$(cat /var/log/Xorg.0.log 2>/dev/null | grep -iE '(ee|ww)' | tail -n 20)\n"
    DEBUG_LOG="$DEBUG_LOG\n=== SUPERVISOR XORG ===\n$(cat /var/log/supervisor/xorg-*.log /home/default/.cache/log/xorg.log 2>/dev/null | tail -n 20)\n"
    DEBUG_LOG="$DEBUG_LOG\n=== SUPERVISOR SUNSHINE ===\n$(cat /var/log/supervisor/sunshine-*.log /home/default/.cache/log/sunshine.log 2>/dev/null | tail -n 20)\n"
    
    report_status "Error: Sunshine no pudo iniciarse." "failed" "$DEBUG_LOG"
    exit 1
fi

report_status "Servidor listo. Conecta con Moonlight." "ready"

) > /home/default/playstone_background.log 2>&1 &
