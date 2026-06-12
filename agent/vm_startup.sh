#!/bin/bash

# ════════════════════════════════════════════════════════════════════════════════
# Playstone Cloud Gaming - Startup Script v3.0 (RunPod Docker Edition)
# ════════════════════════════════════════════════════════════════════════════════
# IMPORTANTE: Este script corre dentro de un CONTENEDOR DOCKER de RunPod.
# - NO hay systemd (no usar systemctl).
# - NO hay acceso al kernel del host (no usar update-initramfs, reboot).
# - Los drivers NVIDIA ya están instalados por el HOST de RunPod.
# - Usamos nohup, bg jobs y /proc/1 para detectar si hay que hacer algo de init.
# ════════════════════════════════════════════════════════════════════════════════

# ── Cargar variables de entorno persistentes ─────────────────────────────────
if [ -f /etc/playstone.env ]; then
    source /etc/playstone.env
    if [ -n "$STEAM_SESSION_B64" ] && [ -z "$STEAM_SESSION" ]; then
        STEAM_SESSION=$(echo -n "$STEAM_SESSION_B64" | base64 -d 2>/dev/null || echo "")
    fi
fi

# ── Idempotency: Evitar ejecuciones paralelas ────────────────────────────────
PIDFILE="/var/run/vm_startup.pid"
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[INIT] Instancia previa (PID $OLD_PID) activa. Terminándola..."
        pkill -9 -P "$OLD_PID" 2>/dev/null || true
        kill -9 "$OLD_PID" 2>/dev/null || true
        sleep 2
    fi
fi
echo $$ > "$PIDFILE"

GAME_ID="${STEAM_APP_ID}"

# ── Guardar variables al /etc/playstone.env si no existe ────────────────────
if [ -n "$SESSION_ID" ] && [ ! -f /etc/playstone.env ]; then
    cat > /etc/playstone.env << ENVEOF
SESSION_ID="$SESSION_ID"
SUPABASE_URL="$SUPABASE_URL"
SUPABASE_KEY="$SUPABASE_KEY"
TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY"
VM_PASSWORD="$VM_PASSWORD"
TAILSCALE_EXTERNAL_IP="$TAILSCALE_EXTERNAL_IP"
TAILSCALE_EXTERNAL_PORT="$TAILSCALE_EXTERNAL_PORT"
RUNPOD_PUBLIC_IP="$RUNPOD_PUBLIC_IP"
STEAM_SESSION_B64="$(echo -n "$STEAM_SESSION" | base64 -w 0 2>/dev/null || echo "")"
ENVEOF
fi

# ── Cargar RUNPOD_PUBLIC_IP si no viene como env (compatibilidad con /etc/playstone.env) ──
if [ -z "$RUNPOD_PUBLIC_IP" ] && [ -f /etc/playstone.env ]; then
    . /etc/playstone.env 2>/dev/null
fi

echo "[$(date)] ═══ Playstone Cloud Gaming v3.0 (Docker) ═══"

# ── Helper: Reportar estado a Supabase ──────────────────────────────────────
report_status() {
    local msg="$1"
    local status="${2:-provisioning}"
    echo "[STATUS] $msg"
    local url="${SUPABASE_URL}"; local key="${SUPABASE_KEY}"; local sid="${SESSION_ID}"
    if [ -n "$url" ] && [ -n "$key" ] && [ -n "$sid" ]; then
        curl -s -X PATCH "$url/rest/v1/sessions?id=eq.$sid" \
             -H "apikey: $key" \
             -H "Authorization: Bearer $key" \
             -H "Content-Type: application/json" \
             -d "{\"status_message\": \"$msg\", \"status\": \"$status\"}" > /dev/null 2>&1 || true
    fi
}

# ── FASE 0: Verificar GPU ────────────────────────────────────────────────────
report_status "Verificando GPU del servidor..."
echo "[INIT] Comprobando drivers NVIDIA..."
if ! nvidia-smi > /dev/null 2>&1; then
    echo "[ERROR] nvidia-smi falló. Abortando."
    report_status "Error: GPU no disponible en este servidor." "failed"
    exit 1
fi
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits | head -n 1)
echo "[OK] GPU detectada: $GPU_NAME"
report_status "GPU OK: $GPU_NAME"

# ── FASE 1: Dependencias base (sin drivers NVIDIA, ya están) ─────────────────
report_status "Paso 1/8: Instalando dependencias base..."

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Liberar locks de dpkg si los hay
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true

# Deshabilitar actualizaciones automáticas para no interferir
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# Agregar arquitectura i386 para Steam
dpkg --add-architecture i386
add-apt-repository multiverse -y 2>/dev/null || true

apt-get update -y \
    -o Acquire::http::Timeout=15 \
    -o Acquire::https::Timeout=15 \
    -o Acquire::Retries=2 \
    -o Dpkg::Use-Pty=0 \
    2>/dev/null || true

# Aceptar licencias de steam
echo "steam steam/license note ''" | debconf-set-selections
echo "steam steam/question select I AGREE" | debconf-set-selections
echo "steamcmd steam/license note ''" | debconf-set-selections
echo "steamcmd steam/question select I AGREE" | debconf-set-selections

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Use-Pty=0 \
    --no-install-recommends \
    steam:i386 steamcmd jq unzip curl wget udev sudo evtest dbus-x11 pciutils \
        psmisc xorg openbox xterm wget curl unzip tar xz-utils mesa-utils vulkan-tools \
        xvfb \
        libgl1-mesa-dri libgl1-mesa-glx libvulkan1 vulkan-tools \
    pulseaudio pavucontrol libnss3 libgconf-2-4 libxss1 libasound2 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libdrm2 libgbm1 libnspr4 libpango-1.0-0 libxkbcommon0 libxcomposite1 libxdamage1 \
    libxfixes3 libxrandr2 libibus-1.0-5 libinput10 \
    nvidia-xconfig libnvidia-gl-535:i386 libvulkan1:i386 mesa-vulkan-drivers:i386 mesa-vulkan-drivers \
    2>/dev/null || \
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    --no-install-recommends \
    steam steamcmd jq unzip curl wget sudo \
    xorg openbox x11-utils xserver-xorg-video-dummy \
    2>/dev/null || true

[ -f /usr/bin/steamcmd ] || ln -s /usr/games/steamcmd /usr/bin/steamcmd 2>/dev/null || true

# Instalar Sunshine
echo "[INIT] Instalando Sunshine..."
wget -qO sunshine.deb https://github.com/LizardByte/Sunshine/releases/download/v0.22.2/sunshine-ubuntu-22.04-amd64.deb
# Mock udevadm para evitar que el script postinst falle por /sys de solo lectura en Docker
mv /bin/udevadm /bin/udevadm.bak 2>/dev/null || true
ln -s /bin/true /bin/udevadm
DEBIAN_FRONTEND=noninteractive apt-get install -y ./sunshine.deb 2>/dev/null || true
rm /bin/udevadm 2>/dev/null || true
mv /bin/udevadm.bak /bin/udevadm 2>/dev/null || true
rm -f sunshine.deb

# Instalar y autenticar Tailscale
echo "[INIT] Instalando Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    # RunPod containers don't have /dev/net/tun, so we must use userspace networking
    nohup tailscaled --tun=userspace-networking --socks5-server=localhost:1055 > /tmp/tailscaled.log 2>&1 &
    sleep 3
    tailscale up --authkey "$TAILSCALE_AUTHKEY" --hostname="ps-vm-${SESSION_ID:0:8}"
    # Guardar IP de Tailscale en Supabase
    TS_IP=$(tailscale ip -4)
    curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
         -H "apikey: ${SUPABASE_KEY}" \
         -H "Authorization: Bearer ${SUPABASE_KEY}" \
         -H "Content-Type: application/json" \
         -d "{\"tailscale_ip\": \"$TS_IP\"}" > /dev/null 2>&1 || true
    echo "[OK] Tailscale conectado. IP: $TS_IP"
fi

report_status "Paso 1/8: Dependencias base y redes instaladas."

# ── FASE 2: Configurar usuario gamer ─────────────────────────────────────────
report_status "Paso 2/8: Configurando usuario gamer..."
id -u gamer &>/dev/null || useradd -m -s /bin/bash gamer
usermod -aG input,video,audio,render gamer 2>/dev/null || true
mkdir -p /home/gamer/game
chown -R gamer:gamer /home/gamer/game

# ── FASE 3: Xvfb (display virtual para contenedores Docker) ─────────────────
report_status "Paso 3/8: Configurando pantalla virtual..."

# En contenedores Docker de RunPod, Xorg no puede usar la GPU para display.
# Usamos Xvfb (X Virtual Framebuffer) + NVENC de NVIDIA para capturar.
# Xvfb crea un display virtual :0 que Sunshine puede usar para capturar.
# NVENC hace el encoding por hardware en la GPU sin necesidad de un monitor real.

# Crear directorio para X11 y Xvfb runtime
mkdir -p /tmp/runtime-gamer /var/run/libvirt

# Asegurar que el usuario gamer tiene acceso a video/dri
chmod 777 /tmp/runtime-gamer 2>/dev/null || true

# Arrancar Xvfb en display virtual :0 (SIN systemd)
pkill -f "Xvfb :0" 2>/dev/null || true
pkill -f "Xorg :0" 2>/dev/null || true
sleep 1

# Xvfb con profundidad 24 bits y resolución 1920x1080
# -ac desactiva control de acceso (necesario para aplicaciones sandbox)
# +extension GLX +RANDR +RENDER para soporte gráfico completo
nohup Xvfb :0 -screen 0 1920x1080x24 +extension GLX +extension RANDR +extension RENDER -ac -noreset > /var/log/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 3

# Verificar que Xvfb está corriendo
if ! ps -p $XVFB_PID > /dev/null 2>&1; then
    echo "[ERROR] Xvfb no pudo iniciar. Verificar /var/log/xvfb.log"
    cat /var/log/xvfb.log
    report_status "Error: No se pudo iniciar display virtual." "failed"
    exit 1
fi

# Arrancar Openbox (window manager ligero) en segundo plano
pkill -f "openbox" 2>/dev/null || true
export DISPLAY=:0
sudo -u gamer DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/runtime-gamer nohup openbox > /var/log/openbox.log 2>&1 &
sleep 2
echo "[OK] Xvfb (PID: $XVFB_PID) y Openbox arrancados en DISPLAY=:0"

# Verificar que el display está disponible
if command -v xdpyinfo > /dev/null 2>&1; then
    XDpyinfo=$(DISPLAY=:0 xdpyinfo 2>&1 | head -1 || echo "FAILED")
    echo "[OK] Display :0 verificado: $XDpyinfo"
fi

# Crear enlace para libGL (necesario para algunas aplicaciones)
if [ -f /usr/lib/x86_64-linux-gnu/libGL.so.1 ]; then
    ln -sf /usr/lib/x86_64-linux-gnu/libGL.so.1 /usr/lib/libGL.so.1 2>/dev/null || true
fi

report_status "Paso 3/8: Pantalla virtual lista (Xvfb + Openbox)."

# ── FASE 5: Autenticación SteamCMD (2FA) ──────────────────────────────────────
report_status "Paso 5/6: Inicializando SteamCMD..."
sudo -u gamer /usr/games/steamcmd +quit > /dev/null 2>&1 || true

if [ -n "$STEAM_USERNAME" ] && [ -n "$STEAM_PASSWORD" ]; then
    STEAM_AUTH_ATTEMPT=1
    while [ $STEAM_AUTH_ATTEMPT -le 3 ]; do
        echo "[STEAM] Intentando login con $STEAM_USERNAME..."
        
        # Ejecutar en background y monitorear el log activamente
        > /tmp/steam_login.log
        sudo -u gamer /usr/games/steamcmd +login "$STEAM_USERNAME" "$STEAM_PASSWORD" +force_install_dir "/home/gamer/.steam/steam/steamapps/common/Game" +app_update "${GAME_ID}" validate +quit > /tmp/steam_login.log 2>&1 &
        STEAM_PID_1=$!
        
        WAIT_TIME_1=0
        LOGIN_SUCCESS_1=false
        while [ $WAIT_TIME_1 -lt 45 ]; do
            if grep -q -E -i "Logging in user.*(Success|OK)" /tmp/steam_login.log 2>/dev/null; then
                LOGIN_SUCCESS_1=true
                break
            fi
            if grep -q -E -i "Steam Guard|Two Factor|Auth Code" /tmp/steam_login.log 2>/dev/null; then
                break
            fi
            if ! kill -0 $STEAM_PID_1 2>/dev/null; then
                break
            fi
            sleep 2
            WAIT_TIME_1=$((WAIT_TIME_1+2))
        done
        
        kill -9 $STEAM_PID_1 2>/dev/null || true
        sudo pkill -9 -u gamer steamcmd 2>/dev/null || true
        
        STEAM_OUT=$(cat /tmp/steam_login.log)
        
        if [ "$LOGIN_SUCCESS_1" = true ] || echo "$STEAM_OUT" | grep -q -i "Logging in user.*Success"; then
            echo "[STEAM] Login exitoso."
            break
        elif echo "$STEAM_OUT" | grep -q -E -i "Steam Guard|Two Factor|Auth Code"; then
            echo "[STEAM] Se requiere Steam Guard (2FA)."
            report_status "La cuenta requiere código Steam Guard." "waiting_steam_auth"
            
            # Esperar por el código 2FA desde Supabase
            STEAM_2FA_CODE=""
            WAIT_TIME=0
            while [ -z "$STEAM_2FA_CODE" ] && [ $WAIT_TIME -lt 180 ]; do
                sleep 5
                WAIT_TIME=$((WAIT_TIME+5))
                SESSION_JSON=$(curl -s -X GET "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}&select=steam_2fa_code" \
                     -H "apikey: ${SUPABASE_KEY}" \
                     -H "Authorization: Bearer ${SUPABASE_KEY}")
                STEAM_2FA_CODE=$(echo "$SESSION_JSON" | jq -r '.[0].steam_2fa_code // empty')
                if [ "$STEAM_2FA_CODE" = "null" ]; then
                    STEAM_2FA_CODE=""
                fi
            done
            
            if [ -n "$STEAM_2FA_CODE" ]; then
                echo "[STEAM] Recibido código 2FA: $STEAM_2FA_CODE. Intentando nuevamente..."
                report_status "Validando código 2FA..." "provisioning"
                
                # Ejecutar en background y monitorear el log activamente
                > /tmp/steam_2fa.log
                sudo -u gamer /usr/games/steamcmd +login "$STEAM_USERNAME" "$STEAM_PASSWORD" "$STEAM_2FA_CODE" +force_install_dir "/home/gamer/.steam/steam/steamapps/common/Game" +app_update "${GAME_ID}" validate +quit > /tmp/steam_2fa.log 2>&1 &
                STEAM_PID=$!
                
                WAIT_TIME=0
                LOGIN_SUCCESS=false
                while [ $WAIT_TIME -lt 45 ]; do
                    if grep -q -E -i "Logging in user.*(Success|OK)" /tmp/steam_2fa.log 2>/dev/null; then
                        LOGIN_SUCCESS=true
                        break
                    fi
                    if ! kill -0 $STEAM_PID 2>/dev/null; then
                        break # Proceso terminó solo
                    fi
                    sleep 2
                    WAIT_TIME=$((WAIT_TIME+2))
                done
                
                # Matar forzosamente a SteamCMD si sigue corriendo (evita que se cuelgue)
                kill -9 $STEAM_PID 2>/dev/null || true
                sudo pkill -9 -u gamer steamcmd 2>/dev/null || true
                
                STEAM_OUT_2FA=$(cat /tmp/steam_2fa.log)
                
                if [ "$LOGIN_SUCCESS" = true ] || echo "$STEAM_OUT_2FA" | grep -q -E -i "Logging in user.*(Success|OK)"; then
                    echo "[STEAM] Login con 2FA exitoso."
                    # Limpiar el código 2FA
                    curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
                         -H "apikey: ${SUPABASE_KEY}" \
                         -H "Authorization: Bearer ${SUPABASE_KEY}" \
                         -H "Content-Type: application/json" \
                         -d "{\"steam_2fa_code\": null}" > /dev/null 2>&1 || true
                    break
                else
                    echo "[STEAM] Falló login con 2FA. Salida: $STEAM_OUT_2FA"
                    CLEAN_ERR_2FA=$(echo "$STEAM_OUT_2FA" | tail -n 3 | tr '\n' ' ' | sed 's/"/'\''/g')
                    report_status "Código 2FA incorrecto o expirado. Error: $CLEAN_ERR_2FA" "waiting_steam_auth"
                    # Limpiar para que pueda pedir otro
                    curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
                         -H "apikey: ${SUPABASE_KEY}" \
                         -H "Authorization: Bearer ${SUPABASE_KEY}" \
                         -H "Content-Type: application/json" \
                         -d "{\"steam_2fa_code\": null}" > /dev/null 2>&1 || true
                fi
            else
                echo "[STEAM] Tiempo de espera por 2FA agotado."
                break
            fi
        else
            echo "[STEAM] Fallo de inicio de sesión: $STEAM_OUT"
            # Capture the last few lines to report back
            CLEAN_ERR=$(echo "$STEAM_OUT" | tail -n 3 | tr '\n' ' ' | sed 's/"/'\''/g')
            report_status "Fallo: $CLEAN_ERR" "failed"
            exit 1
        fi
        
        STEAM_AUTH_ATTEMPT=$((STEAM_AUTH_ATTEMPT+1))
    done
fi

# ── FASE 6: Fix de bwrap/namespaces + Sunshine + Lanzamiento ────────────────
report_status "Paso 6/6: Aplicando fix de user namespaces y arrancando..."

# ─────────────────────────────────────────────────────────────────────────────
# FIX: "Steam now requires user namespaces to be enabled"
#
# RAÍZ DEL PROBLEMA:
# Los contenedores Docker de RunPod bloquean unprivileged user namespaces.
# Steam (desde 2024) requiere bwrap/namespaces para su steam-runtime.
# El chequeo ocurre en DOS lugares:
#   1. steam-runtime-check-requirements (script parcheable)
#   2. El binario steam C++ que llama a bwrap internamente
#
# ESTRATEGIA (en orden de ejecución):
#   A) Dejar que Steam corra UNA VEZ para que se auto-actualice y desempaque
#      su runtime a ubuntu12_32/steam-runtime/
#   B) Parchear los binarios steam-runtime-check-requirements del runtime
#      desempacado (los que Steam realmente usa, no los del tar.xz)
#   C) Sincronizar el checksum interno para que Steam no re-extraiga el runtime
#   D) Crear un bwrap falso en /usr/local/bin que hace exit 0 (para el chequeo C++)
#   E) Re-lanzar Steam con el runtime ya parchado
# ─────────────────────────────────────────────────────────────────────────────

echo "[FIX] Paso A: AppArmor + bubblewrap setuid..."
# Deshabilitar restricción de AppArmor (Ubuntu 24.04+, falla silenciosamente en otros)
echo 0 > /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true
echo "[FIX] apparmor_restrict_unprivileged_userns = $(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo N/A)"

# Intentar setuid en bwrap existente (falla silenciosamente si no está disponible)
apt-get install -y --no-install-recommends bubblewrap 2>/dev/null || true
[ -f /usr/bin/bwrap ] && chmod u+s /usr/bin/bwrap && echo "[FIX] bubblewrap setuid: $(ls -la /usr/bin/bwrap)"

echo "[FIX] Paso B: Crear bwrap falso que no usa namespaces..."
# Este bwrap falso engaña al binario de Steam en C++ que valida namespaces.
# Tiene que estar ANTES de /usr/bin en el PATH para tener prioridad.
mkdir -p /usr/local/bin
cat > /usr/local/bin/bwrap << 'BWRAP_EOF'
#!/bin/bash
# Fake bwrap: ejecuta el comando sin contenedor de namespaces.
# Usado para bypasear la validación de user namespaces en contenedores Docker.
while [[ "$1" == --* ]]; do
    case "$1" in
        --args) shift 2 ;;
        --bind|--ro-bind|--tmpfs|--dev|--proc|--dir) shift 3 ;;
        --setenv|--unsetenv) shift 3 ;;
        --chdir|--hostname|--uid|--gid) shift 2 ;;
        --die-with-parent|--unshare-all|--unshare-user|--unshare-ipc|\
        --unshare-pid|--unshare-net|--unshare-uts|--share-net|\
        --new-session|--as-pid-1) shift ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
exec "$@"
BWRAP_EOF
chmod +x /usr/local/bin/bwrap
echo "[FIX] bwrap falso creado en /usr/local/bin/bwrap"

echo "[FIX] Paso C: Lanzar Steam en modo 'primer arranque' para que se auto-actualice..."
# Steam debe correr una vez para descargar updates y desempacar steam-runtime/
# Lo corremos con timeout para que no se quede esperando interacción
export PATH="/usr/local/bin:$PATH"
BWRAP_PATH=/usr/local/bin/bwrap  # Asegurar que se use el falso

rm -f /tmp/steam_bootstrap.log
sudo -u gamer bash -c '
    export PATH="/usr/local/bin:$PATH"
    export DISPLAY=:0
    export STEAM_RUNTIME=1
    export STEAM_NO_SANDBOX=1
    export STEAM_RUNTIME_PREFER_HOST_BWRAP=1
    nohup /usr/games/steam -no-cef-sandbox -no-sandbox -noreactlogin \
        > /tmp/steam_bootstrap.log 2>&1 &
    echo $!
' > /tmp/steam_bootstrap_pid.txt
STEAM_BOOTSTRAP_PID=$(cat /tmp/steam_bootstrap_pid.txt 2>/dev/null)
echo "[FIX] Steam bootstrap PID: $STEAM_BOOTSTRAP_PID"

# Esperar hasta que el runtime esté desempacado (máximo 90 segundos)
STEAM_RUNTIME_DIR="/home/gamer/.steam/debian-installation/ubuntu12_32/steam-runtime"
WAIT=0
while [ $WAIT -lt 90 ]; do
    if [ -d "$STEAM_RUNTIME_DIR" ] && [ -f "$STEAM_RUNTIME_DIR/checksum" ]; then
        echo "[FIX] steam-runtime desempacado detectado en ${WAIT}s"
        break
    fi
    # También aceptar el directorio .old (Steam lo renombra durante update)
    if [ -d "${STEAM_RUNTIME_DIR}.old" ] && [ -f "${STEAM_RUNTIME_DIR}.old/checksum" ]; then
        echo "[FIX] Encontrado steam-runtime.old, copiando como steam-runtime..."
        cp -a "${STEAM_RUNTIME_DIR}.old" "$STEAM_RUNTIME_DIR"
        chown -R gamer:gamer "$STEAM_RUNTIME_DIR"
        break
    fi
    sleep 3
    WAIT=$((WAIT+3))
done

# Matar Steam del bootstrap (ya cumplió su función de desempacar el runtime)
pkill -f steam 2>/dev/null; pkill -f srt-logger 2>/dev/null; pkill -f zenity 2>/dev/null
sleep 2

echo "[FIX] Paso D: Parchear steam-runtime-check-requirements en el runtime desempacado..."
# Ahora parchamos los binarios REALES que Steam va a ejecutar (no los del tar.xz)
for f in $(find /home/gamer/.steam -name steam-runtime-check-requirements 2>/dev/null); do
    printf '#!/bin/bash\nexit 0\n' > "$f"
    chmod +x "$f"
    chown gamer:gamer "$f" 2>/dev/null || true
    echo "[FIX] Parcheado: $f"
done

# También parchear en /usr/lib/steam si existe
for f in $(find /usr/lib/steam -name steam-runtime-check-requirements 2>/dev/null); do
    printf '#!/bin/bash\nexit 0\n' > "$f"
    chmod +x "$f"
    echo "[FIX] Parcheado: $f"
done

echo "[FIX] Paso E: Sincronizar checksums del runtime para evitar re-extracción..."
# steam.sh compara steam-runtime/checksum con steam-runtime.tar.xz.checksum
# Si coinciden, no extrae nuevamente (y no sobreescribe nuestros parches)
if [ -f "$STEAM_RUNTIME_DIR/checksum" ] && [ -f "${STEAM_RUNTIME_DIR}.tar.xz" ]; then
    # El checksum en steam-runtime/checksum ya tiene el hash del tar original
    # Copiar ese mismo valor al archivo .checksum para que coincidan
    cp "$STEAM_RUNTIME_DIR/checksum" "${STEAM_RUNTIME_DIR}.tar.xz.checksum"
    chown gamer:gamer "${STEAM_RUNTIME_DIR}.tar.xz.checksum" 2>/dev/null || true
    echo "[FIX] Checksums sincronizados."
elif [ ! -f "${STEAM_RUNTIME_DIR}.tar.xz" ]; then
    # Si no hay tar.xz, steam.sh usa el directorio directamente (sin chequeo de checksum)
    echo "[FIX] No hay tar.xz, se usará el directorio steam-runtime directamente."
fi

echo "[FIX] Fix de user namespaces completado en 5 pasos."
report_status "Fix de user namespaces aplicado."

# pv-adverb hack para pressure-vessel (se ejecuta como root)
mkdir -p /usr/lib/pressure-vessel/from-host/libexec/steam-runtime-tools-0/
ln -sf /home/gamer/.steam/debian-installation/steamrt64/pv-runtime/steam-runtime-steamrt/pressure-vessel/libexec/steam-runtime-tools-0/pv-adverb /usr/lib/pressure-vessel/from-host/libexec/steam-runtime-tools-0/pv-adverb

# ── Script de lanzamiento del juego ──────────────────────────────────────────
cat > /home/gamer/launch_game.sh << LAUNCH_EOF
#!/bin/bash
export DISPLAY=:0
export XDG_RUNTIME_DIR=/tmp/runtime-gamer
mkdir -p /tmp/runtime-gamer
# El bwrap falso debe tener prioridad sobre /usr/bin/bwrap del sistema
export PATH="/usr/local/bin:\$PATH"

# Variables de bypass de user namespaces
export STEAM_RUNTIME=1
export STEAM_RUNTIME_PREFER_HOST_BWRAP=1
export STEAM_NO_SANDBOX=1
export STEAM_RUNTIME_HEAVY=0

# En RunPod usamos Xorg dummy que no tiene VK_KHR_surface para nvidia.
# Exportamos VK_ICD_FILENAMES para que el motor del juego use NVIDIA.
# Las dependencias 32-bit (libnss3, etc) ya están instaladas, por lo que steamwebhelper no crasheará.
export VK_ICD_FILENAMES="/etc/vulkan/icd.d/nvidia_icd.json"
# AppArmor fix
echo 0 > /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true

# Auto-reparación si el runtime de Steam está corrupto o fue borrado a medias
if [ -d "/home/gamer/.steam/debian-installation" ] && [ ! -d "/home/gamer/.steam/debian-installation/ubuntu12_32/steam-runtime" ]; then
    echo "[FIX] Steam runtime corrupto o ausente, forzando reinstalación limpia del cliente..."
    rm -rf /home/gamer/.steam/debian-installation
fi

# Re-aplicar parche en caso de que Steam se haya auto-actualizado
for f in \$(find /home/gamer/.steam -name steam-runtime-check-requirements 2>/dev/null); do
    printf '#!/bin/bash\\nexit 0\\n' > "\$f"
    chmod +x "\$f"
done
# También re-crear el bwrap falso si fue sobreescrito
if ! grep -q 'Fake bwrap' /usr/local/bin/bwrap 2>/dev/null; then
    cat > /usr/local/bin/bwrap << 'INNER_BWRAP_EOF'
#!/bin/bash
# Fake bwrap: ejecuta el comando sin contenedor de namespaces.
while [[ "\$1" == --* ]]; do
    case "\$1" in
        --args) shift 2 ;;
        --bind|--ro-bind|--tmpfs|--dev|--proc|--dir) shift 3 ;;
        --setenv|--unsetenv) shift 3 ;;
        --chdir|--hostname|--uid|--gid) shift 2 ;;
        --die-with-parent|--unshare-all|--unshare-user|--unshare-ipc|\
        --unshare-pid|--unshare-net|--unshare-uts|--share-net|\
        --new-session|--as-pid-1) shift ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
exec "\$@"
INNER_BWRAP_EOF
    chmod +x /usr/local/bin/bwrap
fi

echo "[LAUNCH] Iniciando Steam en background..."
nohup /usr/games/steam -gamepadui -no-cef-sandbox -no-sandbox -noreactlogin > /tmp/steam_bg.log 2>&1 &
echo "[LAUNCH] Esperando 5 segundos para que Steam inicialice..."
sleep 5

echo "[LAUNCH] Lanzando juego con ID ${GAME_ID}..."
nohup /usr/games/steam steam://rungameid/${GAME_ID} > /tmp/game_launch.log 2>&1 &
echo "[LAUNCH] Proceso completado."
sleep infinity
LAUNCH_EOF

sed -i "s/REPLACE_GAME_ID/${GAME_ID}/g" /home/gamer/launch_game.sh
chmod +x /home/gamer/launch_game.sh
chown gamer:gamer /home/gamer/launch_game.sh

echo "[INIT] Iniciando launch_game.sh como usuario gamer..."
sudo -u gamer /home/gamer/launch_game.sh &

# Configurar Sunshine
mkdir -p /home/gamer/.config/sunshine
cat << EOF > /home/gamer/.config/sunshine/sunshine.conf
sunshine_name = Playstone Cloud
origin_web_ui_allowed = wan
capture = x11
EOF

# Crear apps.json para forzar que el botón de Steam de Moonlight use launch_game.sh
cat << EOF > /home/gamer/.config/sunshine/apps.json
{
    "env": {
        "PATH": "\$PATH:/usr/local/bin:/usr/bin:/bin"
    },
    "apps": [
        {
            "name": "Desktop",
            "image-path": "desktop.png",
            "cmd": ""
        },
        {
            "name": "Steam",
            "image-path": "steam.png",
            "cmd": "bash /home/gamer/launch_game.sh"
        }
    ]
}
EOF

chown -R gamer:gamer /home/gamer/.config/sunshine

# ── Generar certificado SSL para Sunshine con la IP pública de RunPod ──────────────────
# Moonlight requiere un certificado válido para la IP pública.
# Generamos un certificado autofirmado con subjectAltName que incluye la IP.
if [ -n "$RUNPOD_PUBLIC_IP" ]; then
    echo "[CERT] Generando certificado SSL para IP pública: $RUNPOD_PUBLIC_IP..."
    mkdir -p /home/gamer/.config/sunshine/certs

    # Generar certificado con subjectAltName para la IP pública + localhost
    # RSA 4096 bits, válido 365 días, sin contraseña en la key
    openssl req -x509 -newkey rsa:4096 -keyout /tmp/server.key -out /tmp/server.crt \
        -days 365 -nodes \
        -subj "/CN=Playstone Cloud Gaming" \
        -addext "subjectAltName=IP:${RUNPOD_PUBLIC_IP},IP:127.0.0.1,DNS:localhost,DNS:playstone" \
        2>&1 | tee /tmp/cert_gen.log

    if [ -f /tmp/server.crt ] && [ -f /tmp/server.key ]; then
        cp /tmp/server.crt /home/gamer/.config/sunshine/certs/server.crt
        cp /tmp/server.key /home/gamer/.config/sunshine/certs/server.key
        chmod 600 /home/gamer/.config/sunshine/certs/server.key
        chmod 644 /home/gamer/.config/sunshine/certs/server.crt
        chown -R gamer:gamer /home/gamer/.config/sunshine/certs
        echo "[CERT] ✓ Certificado generado y copiado a ~/.config/sunshine/certs/"
        echo "[CERT]   IP incluida en SAN: $RUNPOD_PUBLIC_IP"
    else
        echo "[CERT] ✗ Error generando certificado. Ver /tmp/cert_gen.log"
        cat /tmp/cert_gen.log
    fi
else
    echo "[CERT] ⚠ RUNPOD_PUBLIC_IP no disponible, saltando generación de certificado."
    echo "[CERT]   (Moonlight puede mostrar advertencia de certificado no verificado)"
fi

sudo -u gamer /usr/bin/sunshine --creds playstone playstone123

# Arrancar Sunshine en background
pkill -9 sunshine 2>/dev/null || true
sleep 2
sudo -u gamer DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/runtime-gamer nohup sunshine /home/gamer/.config/sunshine/sunshine.conf > /tmp/sunshine.log 2>&1 &
echo "[OK] Sunshine arrancado."

# ── Instalar Moonlight Web (WebRTC) con capa de compatibilidad GLIBC 2.39 ─────
# El binario de moonlight-web-stream v2.10.0 requiere GLIBC 2.38/2.39,
# pero Ubuntu 22.04 solo trae GLIBC 2.35.
# Solución: descargar GLIBC 2.39 de Ubuntu 24.04 y usarlo como capa de compat.
echo "[INIT] Instalando Moonlight Web con compatibilidad GLIBC 2.39..."

apt-get install -y patchelf wget -q 2>/dev/null

# Descargar y extraer moonlight-web-stream
mkdir -p /opt/moonlight-web
cd /opt/moonlight-web
wget -qO moonlight-web.tar.gz \
    "https://github.com/MrCreativ3001/moonlight-web-stream/releases/download/v2.10.0/moonlight-web-x86_64-unknown-linux-gnu.tar.gz"
tar -xzf moonlight-web.tar.gz --strip-components=1
rm moonlight-web.tar.gz
chmod +x web-server streamer 2>/dev/null || true

# Descargar GLIBC 2.39 de Ubuntu 24.04 (Noble)
mkdir -p /opt/glibc239
echo "deb http://archive.ubuntu.com/ubuntu noble main" > /tmp/noble.list
NOBLE_VER=$(apt-cache -o Dir::Etc::sourcelist=/tmp/noble.list \
                      -o Dir::Etc::sourceparts=- \
                      show libc6 2>/dev/null | grep ^Version | head -1 | awk '{print $2}')
if [ -n "$NOBLE_VER" ]; then
    cd /opt/glibc239
    apt-get download \
        -o Dir::Etc::sourcelist=/tmp/noble.list \
        -o Dir::Etc::sourceparts=- \
        "libc6=$NOBLE_VER" 2>/dev/null
    dpkg-deb -x libc6_*.deb extract/
    NEWLIBC=/opt/glibc239/extract/usr/lib/x86_64-linux-gnu
    INTERP="$NEWLIBC/ld-linux-x86-64.so.2"
    echo "[INIT] GLIBC 2.39 extraído en $NEWLIBC"
else
    echo "[!] No se pudo obtener GLIBC 2.39. Moonlight Web puede fallar."
    NEWLIBC=""
fi

# Crear directorio server donde va la config
mkdir -p /opt/moonlight-web/server

# Crear config.json en el path que espera el binario (./server/config.json)
cat > /opt/moonlight-web/server/config.json << 'MWCFG'
{
    "web_server": {
        "bind_address": "0.0.0.0:30000"
    }
}
MWCFG

# Copiar certs SSL si existen
if [ -f /tmp/server.key ] && [ -f /tmp/server.crt ]; then
    cp /tmp/server.key /opt/moonlight-web/server/key.pem
    cp /tmp/server.crt /opt/moonlight-web/server/cert.pem
    chmod 644 /opt/moonlight-web/server/*.pem
    cat > /opt/moonlight-web/server/config.json << 'MWCFGSSL'
{
    "web_server": {
        "bind_address": "0.0.0.0:30000",
        "certificate": {
            "private_key_pem": "/opt/moonlight-web/server/key.pem",
            "certificate_pem": "/opt/moonlight-web/server/cert.pem"
        }
    }
}
MWCFGSSL
fi

chown -R gamer:gamer /opt/moonlight-web

# Crear script de lanzamiento que usa el intérprete de GLIBC 2.39 explícitamente
if [ -n "$NEWLIBC" ] && [ -f "$INTERP" ]; then
    cat > /usr/local/bin/start-moonlight-web.sh << LAUNCHER
#!/bin/bash
cd /opt/moonlight-web
# --argv0 es crucial para que web-server encuentre config.json y static/ en este dir
exec $INTERP --library-path $NEWLIBC --argv0 ./web-server ./web-server
LAUNCHER
    echo "[INIT] Usando GLIBC 2.39 para lanzar Moonlight Web..."
else
    # Fallback: intentar ejecutar directamente (puede fallar en Ubuntu 22.04)
    cat > /usr/local/bin/start-moonlight-web.sh << 'LAUNCHER'
#!/bin/bash
cd /opt/moonlight-web
exec ./web-server
LAUNCHER
    echo "[WARN] Usando GLIBC del sistema (puede fallar por versión incompatible)."
fi
chmod +x /usr/local/bin/start-moonlight-web.sh

echo "[INIT] Arrancando Moonlight Web en puerto 30000..."
pkill -f "web-server" 2>/dev/null || true
sleep 1
nohup /usr/local/bin/start-moonlight-web.sh > /tmp/moonlight-web.log 2>&1 &
sleep 5

if ss -tlnp | grep -q 30000; then
    echo "[OK] Moonlight Web Server escuchando en puerto 30000."
else
    echo "[!] Moonlight Web no pudo arrancar. Ver /tmp/moonlight-web.log"
    cat /tmp/moonlight-web.log | head -10
fi

# Crear script de polling para el PIN de Moonlight
cat > /root/poll_moonlight_pin.sh << POLL_EOF
#!/bin/bash
while true; do
    # Consultar PIN
    PIN_RES=\$(curl -s -X GET "${SUPABASE_URL}/rest/v1/sessions?select=moonlight_pin&id=eq.${SESSION_ID}" \
         -H "apikey: ${SUPABASE_KEY}" \
         -H "Authorization: Bearer ${SUPABASE_KEY}")
    
    PIN=\$(echo "\$PIN_RES" | jq -r '.[0].moonlight_pin')
    
    if [ "\$PIN" != "null" ] && [ -n "\$PIN" ] && [ "\$PIN" != "0" ]; then
        echo "[MOONLIGHT] PIN recibido: \$PIN. Emparejando..."
        sudo -u gamer curl -s -k -u playstone:playstone123 -X POST https://localhost:47990/api/pin -H "Content-Type: application/json" -d "{\"pin\": \"\$PIN\", \"name\": \"Playstone\"}"
        # Limpiar PIN en Supabase
        curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
             -H "apikey: ${SUPABASE_KEY}" \
             -H "Authorization: Bearer ${SUPABASE_KEY}" \
             -H "Content-Type: application/json" \
             -d '{"moonlight_pin": null}'
    fi
    sleep 5
done
POLL_EOF
chmod +x /root/poll_moonlight_pin.sh
nohup /root/poll_moonlight_pin.sh > /tmp/moonlight_poll.log 2>&1 &

report_status "Paso 6/6: Sunshine y scripts listos."

# ── FINALIZACIÓN ──────────────────────────────────────────────────────────────
sleep 5
PUB_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "desconocida")
curl -s -X PATCH "${SUPABASE_URL}/rest/v1/sessions?id=eq.${SESSION_ID}" \
     -H "apikey: ${SUPABASE_KEY}" \
     -H "Authorization: Bearer ${SUPABASE_KEY}" \
     -H "Content-Type: application/json" \
     -d "{\"status_message\": \"✅ Listo. Abre Steam Link en tu dispositivo y conéctate.\", \"status\": \"playing\"}" > /dev/null 2>&1 || true
echo "[$(date)] ✅ Configuración completa. IP: $PUB_IP"

echo "[$(date)] Script de inicio completado exitosamente."
