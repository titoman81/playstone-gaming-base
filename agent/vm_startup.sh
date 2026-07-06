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
    
    echo "[STATUS] $msg"
    if [ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_KEY" ] && [ -n "$SESSION_ID" ]; then
        # Escape msg for JSON using jq if available, otherwise fallback
        if command -v jq &> /dev/null; then
            msg=$(echo "$msg" | jq -Rsa .)
        else
            msg=$(python3 -c "import sys, json; print(json.dumps(sys.stdin.read().strip()))" <<< "$msg")
        fi
        
        curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
             -H "apikey: ${SUPABASE_KEY}" \
             -H "Authorization: Bearer ${SUPABASE_KEY}" \
             -H "Content-Type: application/json" \
             -d "{\"status_message\": $msg, \"status\": \"$status\"}" > /dev/null 2>&1 || true
    fi
}

report_status "Servidor arrancando (Steam-Headless)..." "provisioning"

# Force sunshine to use X11 capture to avoid KMS segfaults on virtual displays
echo "[INIT] Aplicando fix de captura X11 para Sunshine..."
mkdir -p /home/default/.config/sunshine
if [ -f /home/default/.config/sunshine/sunshine.conf ]; then
    sed -i '/capture =/d' /home/default/.config/sunshine/sunshine.conf
fi
echo "capture = x11" >> /home/default/.config/sunshine/sunshine.conf
chown -R default:default /home/default/.config/sunshine

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
    # Wait for Sunshine and Moonlight PIN
    MAX_WAIT=180
    ELAPSED=0
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if grep -q "PIN =" /var/log/supervisor/sunshine-stdout*.log 2>/dev/null; then
            MOONLIGHT_PIN=$(grep "PIN =" /var/log/supervisor/sunshine-stdout*.log | tail -n 1 | awk '{print $NF}')
            if [ -n "$MOONLIGHT_PIN" ]; then
                echo "[OK] PIN de Moonlight generado: $MOONLIGHT_PIN"
                
                curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
                     -H "apikey: ${SUPABASE_KEY}" \
                     -H "Authorization: Bearer ${SUPABASE_KEY}" \
                     -H "Content-Type: application/json" \
                     -d "{\"status\": \"running\", \"moonlight_pin\": \"$MOONLIGHT_PIN\"}" > /dev/null 2>&1 || true
                
                break
            fi
        fi
        
        if supervisorctl status sunshine | grep -q "RUNNING"; then
            if [ $ELAPSED -ge 15 ]; then
                echo "[OK] Sunshine en ejecución. PIN manual."
                curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
                     -H "apikey: ${SUPABASE_KEY}" \
                     -H "Authorization: Bearer ${SUPABASE_KEY}" \
                     -H "Content-Type: application/json" \
                     -d "{\"status\": \"running\", \"moonlight_pin\": \"MANUAL\"}" > /dev/null 2>&1 || true
                break
            fi
        fi

        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done

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

echo "[INIT] Esperando a que Sunshine esté disponible (puerto 47990 o proceso activo)..."
report_status "Iniciando servicios de streaming..." "provisioning"

SUNSHINE_READY=0
for i in $(seq 1 36); do
    # Check 1: HTTPS port responds
    if curl -sk --max-time 3 "https://localhost:47990" > /dev/null 2>&1; then
        echo "[OK] Sunshine responde en HTTPS puerto 47990."
        SUNSHINE_READY=1
        break
    fi
    # Check 2: supervisorctl says RUNNING (process is up but HTTPS not yet ready)
    if supervisorctl status sunshine 2>/dev/null | grep -q "RUNNING"; then
        echo "[OK] Sunshine proceso RUNNING (HTTPS puede tardar un poco más)."
        SUNSHINE_READY=1
        break
    fi
    sleep 5
done

if [ "$SUNSHINE_READY" -eq 0 ]; then
    echo "[ERROR] Sunshine no respondió tras 3 minutos."
    
    # Recolectar logs críticos para depuración y guardarlos en status_message
    DEBUG_LOG="Error: Sunshine no pudo iniciarse.\n\n=== XORG CONF ===\n$(cat /etc/X11/xorg.conf 2>/dev/null | head -n 50)\n"
    DEBUG_LOG="$DEBUG_LOG\n=== XORG ERRORS ===\n$(cat /var/log/Xorg.55.log /var/log/Xorg.0.log 2>/dev/null | grep -iE '(ee|ww)' | tail -n 20)\n"
    DEBUG_LOG="$DEBUG_LOG\n=== SUPERVISOR XORG ===\n$(cat /var/log/supervisor/xorg-*.log /home/default/.cache/log/xorg.log 2>/dev/null | tail -n 20)\n"
    DEBUG_LOG="$DEBUG_LOG\n=== SUPERVISOR SUNSHINE ===\n$(cat /var/log/supervisor/sunshine-*.log /home/default/.cache/log/sunshine.log 2>/dev/null | tail -n 20)\n"
    
    report_status "$DEBUG_LOG" "failed"
    exit 1
fi

report_status "Servidor listo. Conecta con Moonlight." "playing"

) > /home/default/playstone_background.log 2>&1 &
