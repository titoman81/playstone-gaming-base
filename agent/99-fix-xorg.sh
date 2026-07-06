#!/bin/bash
if [ -f /etc/X11/xorg.conf ]; then
    echo "Configurando xorg.conf para modo headless con driver dummy..."

    # 1. Cambiar driver de nvidia a dummy
    sed -i 's/Driver         "nvidia"/Driver         "dummy"/g' /etc/X11/xorg.conf

    # 2. Agregar VideoRam al bloque Device (el dummy necesita al menos 256MB declarados)
    #    Insertamos la línea justo antes del cierre del bloque Device
    sed -i '/Driver         "dummy"/a\    VideoRam       262144' /etc/X11/xorg.conf

    # 3. Quitar opciones incompatibles con el driver dummy
    sed -i '/Option.*ModeValidation/d' /etc/X11/xorg.conf
    sed -i '/Option.*AllowEmptyInitialConfiguration/d' /etc/X11/xorg.conf
    sed -i '/Option.*PrimaryGPU/d' /etc/X11/xorg.conf
    sed -i '/Option.*AllowExternalGpus/d' /etc/X11/xorg.conf
    sed -i '/BusID/d' /etc/X11/xorg.conf

    # 4. Inyectar SubSection Display con resolución virtual si no existe
    if ! grep -q "Virtual 1920 1080" /etc/X11/xorg.conf; then
        awk '/Section "Screen"/{print;print "    SubSection \"Display\"\n        Depth 24\n        Virtual 1920 1080\n    EndSubSection";next}1' /etc/X11/xorg.conf > /tmp/xorg.conf && mv /tmp/xorg.conf /etc/X11/xorg.conf
    fi

    echo "xorg.conf actualizado:"
    cat /etc/X11/xorg.conf
fi

# Asegurar capture x11 en Sunshine
mkdir -p /templates/sunshine
echo "capture = x11" >> /templates/sunshine/sunshine.conf
# También para la ruta real de Sunshine en steam-headless
mkdir -p /home/default/.config/sunshine
grep -qxF 'capture = x11' /home/default/.config/sunshine/sunshine.conf 2>/dev/null || echo "capture = x11" >> /home/default/.config/sunshine/sunshine.conf
chown -R default:default /home/default/.config/sunshine 2>/dev/null || true
