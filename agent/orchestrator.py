import httpx
import asyncio
import os
import io
import time
import json
import threading
import runpod
from dotenv import load_dotenv

# Cargar variables de entorno
load_dotenv()

RUNPOD_API_KEY   = os.getenv("RUNPOD_API_KEY", "")
runpod.api_key   = RUNPOD_API_KEY

# GAMING_IMAGE_ID: imagen de Docker que se despliega en el pod.
# ⚠️  Usar una imagen propia con Steam + Sunshine + drivers preinstalados es
#     lo IDEAL para evitar instalarlos desde cero en cada sesión (vm_startup.sh
#     puede tardar 10-20 min si parte de una imagen vacía).
#
# Opciones:
#   · Imagen personalizada subida a Docker Hub / RunPod Templates:
#       TU_USUARIO/playstone-gaming:latest
#   · Imagen RunPod con CUDA ya instalado (más rápida que ubuntu puro):
#       runpod/pytorch:2.1.0-py3.10-cuda12.1.1-devel-ubuntu22.04
#   · Imagen mínima NVIDIA para empezar desde cero:
#       nvidia/cuda:12.4.1-base-ubuntu22.04
#
# Pasos para crear tu imagen personalizada:
#   1. Crear un Dockerfile en agent/Dockerfile con Steam + Sunshine instalados.
#   2. docker build -t TU_USUARIO/playstone-gaming:latest .
#   3. docker push TU_USUARIO/playstone-gaming:latest
#   4. Actualizar GAMING_IMAGE_ID en .env con tu imagen (ahora usamos la oficial por defecto).
GAMING_IMAGE_ID = os.getenv(
    "GAMING_IMAGE_ID",
    "ghcr.io/titoman81/playstone-gaming-base:main"
)

SUPABASE_URL     = os.getenv("SUPABASE_URL", "")
SUPABASE_KEY     = os.getenv("SUPABASE_KEY", "")
SSH_KEY_PUB      = os.getenv("SSH_KEY", "").strip('"').strip("'").strip()

# Ruta al script de arranque (relativo a este archivo)
_HERE = os.path.dirname(os.path.abspath(__file__))
VM_STARTUP_SCRIPT = os.path.join(_HERE, "vm_startup.sh")

# Puertos requeridos por Moonlight + SSH + Tailscale (UDP para NVENC streaming)
PORTS_STRING = "22/tcp,30000/tcp,47984/tcp,47989/tcp,47990/tcp,47998/udp,47999/udp,48000/udp"

# Configuración de GPUs permitidas para Community Cloud (precio máximo $/hr).
# IDs verificados contra la API de RunPod el 2026-06-21.
# Solo se incluyen GPUs con communityCloud=True y stock comprobado.
ALLOWED_GPUS = {
    # ── Ordenadas de más barata a más cara ──────────────────────────────────
    "NVIDIA RTX A4000":               0.25,  # Community+Secure, Low stock, $0.17/hr
    "NVIDIA GeForce RTX 3090":        0.35,  # Community+Secure, Medium stock, $0.22/hr
    "NVIDIA RTX A6000":               0.45,  # Community+Secure, Low stock, $0.33/hr
    "NVIDIA GeForce RTX 4090":        0.55,  # Community+Secure, Low stock, $0.34/hr
    "NVIDIA RTX 5000 Ada Generation": 0.60,  # Community only,  Low stock, $0.49/hr
    "NVIDIA L40":                     0.80,  # Community+Secure, Low stock, $0.69/hr
    "NVIDIA GeForce RTX 5090":        0.80,  # Community+Secure, Low stock, $0.69/hr
    "NVIDIA L40S":                    0.90,  # Community+Secure, Low stock, $0.79/hr
    # Eliminadas: NVIDIA A40 (solo Secure, sin stock community)
    #             NVIDIA RTX A4500/A5000 (sin stock en community cloud)
    #             NVIDIA RTX 3090/4090 (IDs incorrectos - eran sin prefijo 'GeForce')
}
MAX_BUDGET = 1.00


# ─────────────────────────────────────────────────────────────────────────────
# Helpers de Supabase
# ─────────────────────────────────────────────────────────────────────────────

async def report_status(session_id: str, message: str, status: str = "provisioning") -> bool:
    """
    Actualiza el estado de la sesión en Supabase.
    status: provisioning | starting | ready | failed | playing | terminated
    """
    if not session_id or not SUPABASE_URL or not SUPABASE_KEY:
        return False
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.patch(
                f"{SUPABASE_URL}/rest/v1/sessions?id=eq.{session_id}",
                headers={
                    "apikey": SUPABASE_KEY,
                    "Authorization": f"Bearer {SUPABASE_KEY}",
                    "Content-Type": "application/json",
                },
                json={"status_message": message, "status": status},
            )
            r.raise_for_status()
        return True
    except Exception as e:
        print(f"[!] Error reportando estado a Supabase: {e}")
        return False


async def get_session_status(session_id: str) -> str:
    """
    Obtiene el estado actual de la sesión en Supabase.
    Retorna el status (ej. 'terminated', 'provisioning') o None si falla.
    """
    if not session_id or not SUPABASE_URL or not SUPABASE_KEY:
        return None
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(
                f"{SUPABASE_URL}/rest/v1/sessions?id=eq.{session_id}&select=status",
                headers={
                    "apikey": SUPABASE_KEY,
                    "Authorization": f"Bearer {SUPABASE_KEY}",
                    "Content-Type": "application/json",
                }
            )
            r.raise_for_status()
            data = r.json()
            if data and len(data) > 0:
                return data[0].get("status")
        return None
    except Exception as e:
        print(f"[!] Error obteniendo estado de Supabase: {e}")
        return None


async def save_vm_info(session_id: str, pod_id: str, ip: str, ssh_port: int, moonlight_port: int, web_port: int = None) -> bool:
    """
    Guarda la IP pública y los puertos del pod en la sesión de Supabase
    para que el frontend pueda mostrarlos al usuario.
    """
    if not session_id or not SUPABASE_URL or not SUPABASE_KEY:
        return False
    try:
        payload = {
            "instance_id":    pod_id,
            "ip_address":     ip,
        }

        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.patch(
                f"{SUPABASE_URL}/rest/v1/sessions?id=eq.{session_id}",
                headers={
                    "apikey": SUPABASE_KEY,
                    "Authorization": f"Bearer {SUPABASE_KEY}",
                    "Content-Type": "application/json",
                    "Prefer": "return=minimal"
                },
                json=payload,
            )
            # Try to patch web_url if column exists, silently ignore if not
            if web_port:
                web_payload = {"web_url": f"https://{ip}:{web_port}?dataTransport=websocket"}
                await client.patch(
                    f"{SUPABASE_URL}/rest/v1/sessions?id=eq.{session_id}",
                    headers={
                        "apikey": SUPABASE_KEY,
                        "Authorization": f"Bearer {SUPABASE_KEY}",
                        "Content-Type": "application/json",
                        "Prefer": "return=minimal"
                    },
                    json=web_payload,
                )
            r.raise_for_status()
        return True
    except Exception as e:
        print(f"[!] Error guardando info de VM en Supabase: {e}")
        return False


# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap SSH: inyectar vm_startup.sh en el pod via paramiko
# ─────────────────────────────────────────────────────────────────────────────

def _ssh_bootstrap(session_id: str, ip: str, ssh_port: int, env_vars: dict,
                   max_attempts: int = 30, wait_between: int = 10):
    """
    Intenta conectarse por SSH al pod (hasta max_attempts × wait_between segundos)
    y sube + ejecuta vm_startup.sh con las variables de entorno necesarias.

    Corre en un hilo separado para no bloquear el loop asyncio.
    """
    try:
        import paramiko
    except ImportError:
        print("[!] [SSH] paramiko no instalado. Instala con: pip install paramiko")
        return

    if not os.path.exists(VM_STARTUP_SCRIPT):
        print(f"[!] [SSH] vm_startup.sh no encontrado en {VM_STARTUP_SCRIPT}")
        return

    with open(VM_STARTUP_SCRIPT, "r", encoding="utf-8") as f:
        startup_content = f.read()

    # Cabecera de variables de entorno que se antepone al script
    env_header = "#!/bin/bash\n"
    for k, v in env_vars.items():
        # Escapar comillas simples en los valores
        safe_v = str(v).replace("'", "'\\''")
        env_header += f"export {k}='{safe_v}'\n"

    # Reemplazar el shebang original para insertar el header con las variables
    lines = startup_content.splitlines()
    if lines and lines[0].startswith("#!"):
        full_script = lines[0] + "\n" + env_header + "\n".join(lines[1:])
    else:
        full_script = env_header + startup_content

    pkey = None
    # Intentar cargar la clave privada SSH (id_rsa) del sistema
    for key_path in [
        os.path.expanduser("~/.ssh/id_rsa_playstone"),
        os.path.expanduser("~/.ssh/id_rsa"),
        os.path.expanduser("~/.ssh/id_ed25519"),
    ]:
        if os.path.exists(key_path):
            try:
                pkey = paramiko.RSAKey.from_private_key_file(key_path)
                print(f"[SSH] Usando clave privada: {key_path}")
                break
            except Exception:
                try:
                    pkey = paramiko.Ed25519Key.from_private_key_file(key_path)
                    print(f"[SSH] Usando clave privada Ed25519: {key_path}")
                    break
                except Exception:
                    pass

    for attempt in range(1, max_attempts + 1):
        print(f"[*] [SSH] Intento de conexion {attempt}/{max_attempts} -> {ip}:{ssh_port}...")
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            connect_kwargs = {"hostname": ip, "port": ssh_port, "username": "root", "timeout": 15}
            if pkey:
                connect_kwargs["pkey"] = pkey
            else:
                connect_kwargs["look_for_keys"] = True
                connect_kwargs["allow_agent"] = True

            client.connect(**connect_kwargs)
            print("[+] [SSH] Conectado exitosamente.")

            # Subir el script
            sftp = client.open_sftp()
            remote_path = "/tmp/vm_startup.sh"
            with sftp.open(remote_path, "w") as rf:
                rf.write(full_script)
            sftp.chmod(remote_path, 0o755)
            sftp.close()
            print("[+] [SSH] Script subido a /tmp/vm_startup.sh")

            # Ejecutar en background con nohup
            _, stdout, stderr = client.exec_command(
                f"nohup bash {remote_path} > /tmp/vm_startup.log 2>&1 &",
                timeout=15
            )
            print("[+] [SSH] Script ejecutado en segundo plano (nohup).")
            client.close()
            return  # Éxito

        except Exception as e:
            print(f"[*] [SSH] Aún no disponible ({e}). Esperando {wait_between}s...")
            try:
                client.close()
            except Exception:
                pass
            time.sleep(wait_between)

    print(f"[!] [SSH] No se pudo conectar a {ip}:{ssh_port} tras {max_attempts} intentos.")

def _pair_moonlight_pin(ip: str, ssh_port: int, pin: str) -> bool:
    """Ejecuta el emparejamiento del PIN a través de SSH en la VM de destino llamando a la API local de Sunshine."""
    try:
        import paramiko
    except ImportError:
        print("[!] [SSH] paramiko no instalado.")
        return False
        
    pkey = None
    for key_path in [
        os.path.expanduser("~/.ssh/id_rsa_playstone"),
        os.path.expanduser("~/.ssh/id_rsa"),
        os.path.expanduser("~/.ssh/id_ed25519"),
    ]:
        if os.path.exists(key_path):
            try:
                pkey = paramiko.RSAKey.from_private_key_file(key_path)
                break
            except Exception:
                try:
                    pkey = paramiko.Ed25519Key.from_private_key_file(key_path)
                    break
                except Exception:
                    pass

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        connect_kwargs = {"hostname": ip, "port": ssh_port, "username": "root", "timeout": 10}
        if pkey: connect_kwargs["pkey"] = pkey
        client.connect(**connect_kwargs)
        
        # Enviar PIN a la API de Sunshine localmente
        # NOTA: En Sunshine v0.22+, a veces la API devuelve un status que podemos chequear, pero para emparejamiento 
        # asincrono basta con enviar la request.
        cmd = f"curl -k -s -o /dev/null -w '%{{http_code}}' -X POST -u playstone:playstone123 -H 'Content-Type: application/json' -d '{{\"pin\":\"{pin}\", \"salt\":\"\"}}' https://127.0.0.1:47990/api/pin"
        _, stdout, _ = client.exec_command(cmd, timeout=10)
        code = stdout.read().decode().strip()
        client.close()
        
        if code in ["200", "202"]:
            print(f"[+] [SSH] PIN de Moonlight ({pin}) enviado exitosamente a {ip}.")
            return True
        else:
            print(f"[!] [SSH] Error al enviar PIN. Código HTTP devuelto por Sunshine: {code}")
            # Consideramos exito de todos modos para que se limpie y no bloquee
            return True
    except Exception as e:
        print(f"[!] [SSH] Error conectando para PIN: {e}")
        return False

# ─────────────────────────────────────────────────────────────────────────────
# Orquestador principal
# ─────────────────────────────────────────────────────────────────────────────

class PlaystoneOrchestrator:
    def __init__(self):
        self.api_url = "https://api.runpod.io/graphql"
        self.headers = {
            "Authorization": f"Bearer {RUNPOD_API_KEY}",
            "Content-Type": "application/json",
        }

    # ── Consultar stock de GPUs disponibles en Secure Cloud ──────────────────

    async def get_available_gpus(self) -> list:
        """
        Consulta la API de RunPod para obtener todas las GPUs con stock en Community Cloud.
        Devuelve una lista de IDs de GPU disponibles.
        """
        query = """
        query GetGPUStock {
            gpuTypes {
                id
                communityCloud
                communityPrice: lowestPrice(input: { gpuCount: 1, secureCloud: false }) {
                    stockStatus
                }
                securePrice: lowestPrice(input: { gpuCount: 1, secureCloud: true }) {
                    stockStatus
                }
            }
        }
        """
        try:
            async with httpx.AsyncClient(timeout=20) as client:
                r = await client.post(self.api_url, json={"query": query}, headers=self.headers)
                if r.status_code != 200:
                    print(f"HTTP {r.status_code}: {r.text}")
                r.raise_for_status()
                data   = r.json()
                errors = data.get("errors")
                if errors:
                    print(f"[!] get_available_gpus GraphQL error: {errors[0].get('message')}")
                    return list(ALLOWED_GPUS.keys()) # Fallback

                gpu_list = data.get("data", {}).get("gpuTypes", [])
                available = []
                for gpu in gpu_list:
                    c_stock = (gpu.get("communityPrice") or {}).get("stockStatus") or ""
                    s_stock = (gpu.get("securePrice") or {}).get("stockStatus") or ""
                    
                    is_c_avail = c_stock.upper() not in ("OUT_OF_STOCK", "NO_STOCK", "UNAVAILABLE", "")
                    is_s_avail = s_stock.upper() not in ("OUT_OF_STOCK", "NO_STOCK", "UNAVAILABLE", "")
                    
                    if is_c_avail or is_s_avail:
                        available.append(gpu.get("id"))
                
                print(f"[*] Stock global obtenido: {len(available)} modelos de GPU disponibles en RunPod.")
                return available
        except Exception as e:
            print(f"[!] Error consultando stock global de GPUs: {e}")
            # Si falla la consulta, devolvemos las ALLOWED_GPUS por defecto para intentar a ciegas
            return list(ALLOWED_GPUS.keys())

    # ── Consultar pods activos ────────────────────────────────────────────────

    # ── Circuit-breaker: si la API falla N veces seguidas, levantamos excepción ─
    _api_fail_count:  int = 0
    _API_FAIL_LIMIT:  int = 5   # tras 5 errores consecutivos de API se aborta

    async def get_active_pods(self) -> list:
        """
        Devuelve la lista de pods activos del usuario de RunPod.
        Circuit-breaker: si la API falla más de _API_FAIL_LIMIT veces seguidas
        (error HTTP, JSON inválido, GraphQL error de autenticación) lanza
        RuntimeError para que el llamador pueda abortar el flujo en lugar de
        iterar indefinidamente.
        """
        query = """
        query GetActivePods {
            myself {
                pods {
                    id
                    name
                    desiredStatus
                    runtime {
                        uptimeInSeconds
                        ports {
                            ip
                            isIpPublic
                            privatePort
                            publicPort
                        }
                    }
                }
            }
        }
        """
        try:
            async with httpx.AsyncClient(timeout=20) as client:
                r = await client.post(self.api_url, json={"query": query}, headers=self.headers)
                if r.status_code != 200:
                    print(f"HTTP {r.status_code}: {r.text}")
                r.raise_for_status()
                data = r.json()
                errors = data.get("errors")
                if errors:
                    # Errores GraphQL (p.ej. API Key inválida)
                    msg = errors[0].get("message", str(errors))
                    raise RuntimeError(f"RunPod GraphQL error: {msg}")
                self._api_fail_count = 0   # reset tras éxito
                return data.get("data", {}).get("myself", {}).get("pods", [])
        except RuntimeError:
            raise   # propagar circuit-breaker
        except Exception as e:
            self._api_fail_count += 1
            print(f"[!] Error consultando pods activos ({self._api_fail_count}/{self._API_FAIL_LIMIT}): {e}")
            if self._api_fail_count >= self._API_FAIL_LIMIT:
                raise RuntimeError(
                    f"Circuit-breaker: API de RunPod falló {self._api_fail_count} veces seguidas. "
                    "Verifica RUNPOD_API_KEY y conectividad."
                )
            return []

    def _extract_ip_and_ports(self, pod: dict) -> tuple[str | None, int, int, int]:
        """
        Extrae IP pública, puerto SSH externo, puerto Moonlight (47989) y puerto web (30000).
        """
        runtime = pod.get("runtime") or {}
        ports   = runtime.get("ports") or []

        ip            = None
        ssh_ext       = 22
        moonlight_ext = 47989   # fallback si no aparece mapeado
        web_ext       = None

        for p in ports:
            if p.get("isIpPublic") and p.get("ip") and not ip:
                ip = p["ip"]
            if p.get("privatePort") == 22:
                ssh_ext = p.get("publicPort", 22)
            if p.get("privatePort") == 47989:
                moonlight_ext = p.get("publicPort", 47989)
            if p.get("privatePort") == 30000:
                web_ext = p.get("publicPort")

        return ip, ssh_ext, moonlight_ext, web_ext

    # ── Deploy principal ──────────────────────────────────────────────────────

    async def deploy_gaming_pod(
        self,
        gpu_type="AUTO",
        session_id=None,
        user_id=None,
        steam_username=None,
        steam_password=None,
        steam_app_id=None,
        game_name="Juego",
        launcher="steam",
        lutris_slug="",
        epic_app_name="",
        tailscale_authkey=None,
    ):
        if not RUNPOD_API_KEY:
            print("[!] RUNPOD_API_KEY no configurada. Abortando.")
            await report_status(session_id, "Error de configuración: API Key ausente.", "failed")
            return None

        pod_id = None

        # ── Evitar duplicados ────────────────────────────────────────────────
        active_pods = await self.get_active_pods()
        for pod in active_pods:
            if not pod.get("name"):
                continue
            if session_id and session_id[:8] in pod.get("name", "") and pod.get("status") != "TERMINATED":
                pod_id = pod["id"]
                ip, ssh_port, ml_port, web_port = self._extract_ip_and_ports(pod)
                print(f"[+] Pod ya existe para sesión {session_id[:8]} (ID: {pod_id}).")
                if ip:
                    # Pod ya tiene IP — guardar y reconectar directamente
                    await save_vm_info(session_id, pod_id, ip, ssh_port, ml_port, web_port)
                    await report_status(session_id, f"Pod reconectado en {ip}.", "provisioning")
                    # Lanzar bootstrap SSH también en este caso
                    env_vars = {
                        "SESSION_ID":    session_id or "",
                        "SUPABASE_URL":  SUPABASE_URL,
                        "SUPABASE_KEY":  SUPABASE_KEY,
                        "STEAM_APP_ID":  steam_app_id or "",
                        "GAME_NAME":     game_name,
                        "RUNPOD_PUBLIC_IP": ip,
                    }
                    if steam_username: env_vars["STEAM_USERNAME"] = steam_username
                    if steam_password: env_vars["STEAM_PASSWORD"] = steam_password
                    if tailscale_authkey: env_vars["TAILSCALE_AUTHKEY"] = tailscale_authkey
                    t = threading.Thread(target=_ssh_bootstrap, args=(session_id, ip, ssh_port, env_vars), daemon=True)
                    t.start()
                    return pod_id
                else:
                    # Pod existe pero aún sin IP — esperar en el loop normal más abajo
                    print(f"[*] Pod {pod_id} encontrado pero sin IP aún. Esperando en loop...")
                    break

        # ── Buscar máquina dormida para este usuario y juego ─────────────────
        if user_id and steam_app_id:
            try:
                async with httpx.AsyncClient(timeout=10) as client:
                    r_sleep = await client.get(
                        f"{SUPABASE_URL}/rest/v1/sessions?user_id=eq.{user_id}&status=eq.sleeping&instance_id=not.is.null&order=created_at.desc&limit=1",
                        headers={
                            "apikey": SUPABASE_KEY,
                            "Authorization": f"Bearer {SUPABASE_KEY}",
                            "Content-Type": "application/json"
                        }
                    )
                    r_sleep.raise_for_status()
                    sleep_data = r_sleep.json()
                    
                    if sleep_data:
                        old_session = sleep_data[0]
                        sleeping_pod_id = old_session.get("instance_id")
                        old_session_id = old_session.get("id")
                        
                        # Validar que sea del mismo juego (hay que extraer el steam_app_id o game_id)
                        # Haremos una llamada rápida para ver si el game_id coincide con el actual
                        # Para no complicar, asumimos que si user_id y status=sleeping coinciden, es una máquina suya.
                        # Mejor: asegurarnos que es del mismo juego
                        # Vamos a comprobar si el pod_id todavía existe en RunPod (podría haber sido borrado)
                        pod_still_exists = any(p["id"] == sleeping_pod_id for p in active_pods if p.get("status") != "TERMINATED")
                        if pod_still_exists:
                            print(f"[*] Encontrada máquina dormida para usuario (Pod: {sleeping_pod_id}). Reanudando...")
                            await report_status(session_id, "Despertando máquina dormida...", "provisioning")
                            success = await self.resume_pod(sleeping_pod_id)
                            if success:
                                # Marcar la antigua como terminada para que no vuelva a interferir
                                await client.patch(
                                    f"{SUPABASE_URL}/rest/v1/sessions?id=eq.{old_session_id}",
                                    headers={"apikey": SUPABASE_KEY, "Authorization": f"Bearer {SUPABASE_KEY}", "Content-Type": "application/json"},
                                    json={"status": "terminated"}
                                )
                                # Cambiar el pod_id a usar por el sleeping_pod_id
                                pod_id = sleeping_pod_id
                                # No necesitamos buscar GPU, saltaremos el bucle de abajo
            except Exception as e:
                print(f"[!] Error buscando/reanudando máquina dormida: {e}")

        if not pod_id:
            # ── Lógica AUTO-GPU Dinámica ─────────────────────────────────────────
            await report_status(session_id, "Consultando stock de GPUs en tiempo real...", "provisioning")
            available_gpus = await self.get_available_gpus()
            
            # Si gpu_type es AUTO o no está en la lista, iterar todas las que tienen stock, ordenadas por precio
            if gpu_type == "AUTO" or gpu_type not in ALLOWED_GPUS:
                valid_gpus = [g for g in available_gpus if g in ALLOWED_GPUS and ALLOWED_GPUS[g] <= MAX_BUDGET]
                gpus_to_try = sorted(valid_gpus, key=lambda g: ALLOWED_GPUS[g])
                if not gpus_to_try:
                    print("[!] Ninguna GPU permitida tiene stock en este momento.")
            else:
                if ALLOWED_GPUS[gpu_type] > MAX_BUDGET:
                    await report_status(session_id, f"Error: GPU {gpu_type} excede el presupuesto.", "failed")
                    return None
                if gpu_type in available_gpus:
                    gpus_to_try = [gpu_type]
                else:
                    print(f"[!] La GPU solicitada '{gpu_type}' no tiene stock actualmente.")
                    gpus_to_try = []
        else:
            gpus_to_try = [] # No intentar ninguna GPU nueva si ya tenemos pod_id

        vm_name = f"ps-vm-{session_id[:8]}" if session_id else "ps-vm-playstone"
        selected_gpu = None

        mutation = """
        mutation CreateGamingPod($input: PodFindAndDeployOnDemandInput!) {
            podFindAndDeployOnDemand(input: $input) {
                id name desiredStatus
                runtime { ports { ip isIpPublic privatePort publicPort } }
            }
        }
        """

        for current_gpu in gpus_to_try:
            print(f"[*] Intentando desplegar pod con {current_gpu}...")
            await report_status(session_id, f"Reservando servidor con {current_gpu}...", "provisioning")
            
            env_vars = [
                        {"key": "SESSION_ID",    "value": session_id or ""},
                        {"key": "SUPABASE_URL",  "value": SUPABASE_URL},
                        {"key": "SUPABASE_KEY",  "value": SUPABASE_KEY},
                        {"key": "STEAM_APP_ID",  "value": steam_app_id},
                        {"key": "GAME_ID",       "value": steam_app_id},  # alias para launch_game.sh
                        {"key": "GAME_NAME",     "value": game_name},
                        {"key": "TAILSCALE_AUTHKEY", "value": tailscale_authkey or ""},
                        # ── Multi-launcher ────────────────────────────────────────────
                        {"key": "LAUNCHER",     "value": launcher or "steam"},
                        {"key": "LUTRIS_SLUG",  "value": lutris_slug or ""},
                        {"key": "EPIC_APP_NAME","value": epic_app_name or ""},
                        # ── NVIDIA: habilitar GPU completa para NVENC/Sunshine ────────
                        {"key": "NVIDIA_VISIBLE_DEVICES",      "value": "all"},
                        {"key": "NVIDIA_DRIVER_CAPABILITIES",  "value": "all"},
                        # -- Steam-Headless: variables nativas de la imagen base ----
                        {"key": "ENABLE_STEAM",           "value": "true"},
                        {"key": "ENABLE_SUNSHINE",        "value": "true"},
                        {"key": "SUNSHINE_USER",          "value": "playstone"},
                        {"key": "SUNSHINE_PASS",          "value": "playstone123"},
                        {"key": "FORCE_X11_DUMMY_CONFIG", "value": "true"},
                        {"key": "USER_LOCALES",           "value": "en_US.UTF-8 UTF-8"},
                        {"key": "TZ",                     "value": "UTC"},
            ]
            if steam_username: env_vars.append({"key": "STEAM_USERNAME", "value": steam_username})
            if steam_password: env_vars.append({"key": "STEAM_PASSWORD", "value": steam_password})
            
            variables = {
                "input": {
                    "name":              vm_name,
                    "imageName":         GAMING_IMAGE_ID,
                    "gpuTypeId":         current_gpu,
                    "cloudType":         "ALL",
                    "countryCode":       "US",
                    "gpuCount":          1,
                    "ports":             "30000/tcp,47984/tcp,47989/tcp,47990/tcp,47998/udp,47999/udp,48000/udp",
                    "volumeInGb":        10,
                    "volumeMountPath":   "/runpod-volume",
                    "containerDiskInGb": 100,
                    "minVcpuCount":      2,
                    "minMemoryInGb":     8,
                    "env":               env_vars
                }
            }

            try:
                async with httpx.AsyncClient(timeout=30) as client:
                    r = await client.post(self.api_url, json={"query": mutation, "variables": variables}, headers=self.headers)
                    try:
                        data = r.json()
                    except Exception:
                        data = {}
                    if not r.is_success:
                        raw = r.text[:500]
                        print(f"[!] HTTP {r.status_code} al reservar {current_gpu}: {raw}")
                        continue
                    if data.get("errors"):
                        err_msg = data["errors"][0].get("message", str(data["errors"]))
                        err_code = data["errors"][0].get("extensions", {}).get("code", "")
                        if err_code == "SUPPLY_CONSTRAINT" or "no longer any instances available" in err_msg or "does not have the resources" in err_msg:
                            print(f"[!] Sin stock (SUPPLY_CONSTRAINT) para {current_gpu}, intentando la siguiente...")
                            continue
                        raise Exception(err_msg)

                    pod_id = data.get("data", {}).get("podFindAndDeployOnDemand", {}).get("id")
                    if pod_id:
                        print(f"[+] Pod creado: {pod_id} con {current_gpu}")
                        selected_gpu = current_gpu
                        break
            except Exception as e:
                print(f"[!] Error inesperado reservando {current_gpu}: {e}")
                continue # Pasa a la siguiente GPU
        
        if not pod_id:
            msg = "GPUs agotadas o sin stock en la nube segura. Intenta más tarde."
            print(f"[!] {msg}")
            await report_status(session_id, msg, "failed")
            return None

        # ── Esperar a que el pod esté RUNNING con IP pública ─────────────────
        print(f"[*] Esperando IP pública para pod {pod_id} (GPU: {selected_gpu or 'Misma'})...")
        ip, ssh_port, ml_port, web_port = None, 22, 47989, 30000

        start_wait = time.time()
        timeout = 20 * 60  # 20 minutos (para dar tiempo a descargar la imagen de 8GB)
        while time.time() - start_wait < timeout:
            await asyncio.sleep(5)
            
            # ── Comprobar si el usuario canceló la sesión desde el frontend ──
            current_status = await get_session_status(session_id)
            if current_status in ["terminated", "failed"]:
                print(f"[!] El usuario canceló la sesión {session_id} durante el aprovisionamiento.")
                print(f"[*] Terminando el pod huérfano {pod_id}...")
                await self.terminate_pod(pod_id)
                return None

            elapsed_wait = int(time.time() - start_wait)
            pods = await self.get_active_pods()
            pod_info = next((p for p in pods if p["id"] == pod_id), None)
            if not pod_info:
                continue
            
            status = pod_info.get("desiredStatus")
            ip, ssh_port, ml_port, web_port = self._extract_ip_and_ports(pod_info)
            
            if status == "RUNNING" and ip:
                print(f"[+] Pod listo. IP: {ip} | SSH: {ssh_port} | Moonlight: {ml_port}")
                break
            elif ip:
                await report_status(session_id, f"Servidor arrancando... ({elapsed_wait}s)", "provisioning")
                print(f"[*] IP asignada ({ip}), esperando estado RUNNING...")
            else:
                await report_status(session_id, f"Esperando IP del servidor... ({elapsed_wait}s)", "provisioning")

        if not ip:
            print(f"[!] Timeout esperando IP del pod {pod_id}.")
            await report_status(session_id, "Tiempo de espera agotado (20 min). El servidor no respondió.", "failed")
            print(f"[*] Terminando el pod {pod_id} debido a timeout...")
            await self.terminate_pod(pod_id)
            return None

        # ── Guardar IP + puertos en Supabase ──────────────────────────────────
        await save_vm_info(session_id, pod_id, ip, ssh_port, ml_port, web_port)
        await report_status(session_id, f"Servidor arrancando en {ip}. Esperando inicialización interna...", "provisioning")

        # No SSH bootstrap needed. The dockerArgs injection handles it!
        return pod_id


    # ── Terminar pod ──────────────────────────────────────────────────────────

    async def terminate_pod(self, pod_id: str) -> bool:
        """Termina un pod por su ID."""
        print(f"[*] Terminando pod {pod_id}...")
        mutation = """
        mutation podTerminate($input: PodTerminateInput!) {
            podTerminate(input: $input)
        }
        """
        try:
            async with httpx.AsyncClient(timeout=20) as client:
                r = await client.post(
                    self.api_url,
                    json={"query": mutation, "variables": {"input": {"podId": pod_id}}},
                    headers=self.headers,
                )
                r.raise_for_status()
                errors = r.json().get("errors")
                if errors:
                    raise Exception(errors[0].get("message", str(errors)))
            print(f"[+] Pod {pod_id} terminado.")
            return True
        except Exception as e:
            print(f"[!] Error terminando pod {pod_id}: {e}")
            return False

    async def stop_pod(self, pod_id: str) -> bool:
        """
        Detiene (pausa) el pod de RunPod para no facturar GPU, manteniendo el volumen.
        """
        if not RUNPOD_API_KEY: return False
        mutation = """
        mutation StopPod($input: PodStopInput!) {
            podStop(input: $input) { id }
        }
        """
        try:
            async with httpx.AsyncClient(timeout=20) as client:
                r = await client.post(
                    self.api_url,
                    json={"query": mutation, "variables": {"input": {"podId": pod_id}}},
                    headers=self.headers,
                )
                r.raise_for_status()
                errors = r.json().get("errors")
                if errors:
                    raise Exception(errors[0].get("message", str(errors)))
            print(f"[+] Pod {pod_id} detenido (durmiendo).")
            return True
        except Exception as e:
            print(f"[!] Error deteniendo pod {pod_id}: {e}")
            return False

    async def resume_pod(self, pod_id: str) -> bool:
        """
        Reanuda un pod detenido en RunPod.
        """
        if not RUNPOD_API_KEY: return False
        mutation = """
        mutation ResumePod($input: PodResumeInput!) {
            podResume(input: $input) { id }
        }
        """
        try:
            async with httpx.AsyncClient(timeout=20) as client:
                r = await client.post(
                    self.api_url,
                    json={"query": mutation, "variables": {"input": {"podId": pod_id, "gpuCount": 1}}},
                    headers=self.headers,
                )
                r.raise_for_status()
                errors = r.json().get("errors")
                if errors:
                    raise Exception(errors[0].get("message", str(errors)))
            print(f"[+] Pod {pod_id} reanudado.")
            return True
        except Exception as e:
            print(f"[!] Error reanudando pod {pod_id}: {e}")
            return False


# ─────────────────────────────────────────────────────────────────────────────
# Demonio principal (Long-running)
# ─────────────────────────────────────────────────────────────────────────────

async def orchestrator_daemon():
    orch = PlaystoneOrchestrator()
    print("[*] Iniciando Orquestador Playstone. Esperando sesiones 'pending' en Supabase...")
    
    while True:
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                r = await client.get(
                    f"{SUPABASE_URL}/rest/v1/sessions?status=eq.pending&select=*,games(*)",
                    headers={
                        "apikey": SUPABASE_KEY,
                        "Authorization": f"Bearer {SUPABASE_KEY}",
                        "Content-Type": "application/json"
                    }
                )
                r.raise_for_status()
                pending_sessions = r.json()
                
                for sess in pending_sessions:
                    session_id     = sess.get("id")
                    game           = sess.get("games") or {}
                    steam_app_id   = str(game.get("steam_app_id", ""))
                    game_name      = game.get("name", "Juego")
                    steam_username = sess.get("steam_username", "")
                    steam_password = sess.get("steam_password", "")
                    tailscale_authkey = sess.get("tailscale_authkey", "")
                    user_id        = sess.get("user_id", "")
                    # ── Multi-launcher: extraídos del registro de juego ───────
                    launcher       = game.get("launcher", "steam") or "steam"
                    lutris_slug    = game.get("lutris_slug", "") or ""
                    epic_app_name  = game.get("epic_app_name", "") or ""
                    
                    print(f"[*] Nueva sesión pendiente: {session_id} ({game_name}) [launcher={launcher}]")
                    
                    # Cambiar estado a provisioning inmediatamente para no re-procesar
                    await report_status(session_id, "Iniciando asignación de servidor...", "provisioning")
                    
                    asyncio.create_task(orch.deploy_gaming_pod(
                        gpu_type="AUTO",
                        session_id=session_id,
                        user_id=user_id,
                        steam_username=steam_username,
                        steam_password=steam_password,
                        steam_app_id=steam_app_id,
                        game_name=game_name,
                        launcher=launcher,
                        lutris_slug=lutris_slug,
                        epic_app_name=epic_app_name,
                        tailscale_authkey=tailscale_authkey,
                    ))

            # ── Terminar pods de sesiones completadas o terminadas (canceladas) ──
            async with httpx.AsyncClient(timeout=10) as client:
                r_comp = await client.get(
                    f"{SUPABASE_URL}/rest/v1/sessions?status=in.(completed,terminated)&instance_id=not.is.null",
                    headers={
                        "apikey": SUPABASE_KEY,
                        "Authorization": f"Bearer {SUPABASE_KEY}",
                        "Content-Type": "application/json"
                    }
                )
                r_comp.raise_for_status()
                completed_sessions = r_comp.json()
                
                for sess in completed_sessions:
                    session_id = sess.get("id")
                    pod_id = sess.get("instance_id")
                    if pod_id:
                        print(f"[*] Limpiando sesión completada {session_id} (Pod: {pod_id})")
                        # Lanzar terminate en background
                        asyncio.create_task(cleanup_pod(orch, session_id, pod_id))

            # ── Suspender pods (Dormir) ───────────────────────────────────────────────
            async with httpx.AsyncClient(timeout=10) as client:
                r_sleep = await client.get(
                    f"{SUPABASE_URL}/rest/v1/sessions?status=eq.sleeping_requested&instance_id=not.is.null",
                    headers={
                        "apikey": SUPABASE_KEY,
                        "Authorization": f"Bearer {SUPABASE_KEY}",
                        "Content-Type": "application/json"
                    }
                )
                r_sleep.raise_for_status()
                sleeping_sessions = r_sleep.json()
                
                for sess in sleeping_sessions:
                    session_id = sess.get("id")
                    pod_id = sess.get("instance_id")
                    if pod_id:
                        print(f"[*] Suspendiendo sesión {session_id} (Pod: {pod_id})")
                        asyncio.create_task(suspend_pod(orch, session_id, pod_id))

            # ── Procesar PINs de Moonlight ────────────────────────────────────
            async with httpx.AsyncClient(timeout=10) as client:
                r_pin = await client.get(
                    f"{SUPABASE_URL}/rest/v1/sessions?moonlight_pin=not.is.null&status=neq.completed&status=neq.terminated",
                    headers={
                        "apikey": SUPABASE_KEY,
                        "Authorization": f"Bearer {SUPABASE_KEY}",
                        "Content-Type": "application/json"
                    }
                )
                r_pin.raise_for_status()
                pin_sessions = r_pin.json()
                
                for sess in pin_sessions:
                    session_id = sess.get("id")
                    pin = sess.get("moonlight_pin")
                    ip = sess.get("ip_address")
                    
                    if pin and ip:
                        print(f"[*] Detectado PIN de Moonlight para sesión {session_id[:8]}...")
                        # Obtener puerto SSH (default 22 o el puerto guardado en metadata, 
                        # pero por simplicidad el orquestador lo buscaría de pod_ip)
                        # Nota: En RunPod el puerto SSH expuesto cambia. Buscamos el pod real para obtenerlo.
                        active_pods = await orch.get_active_pods()
                        ssh_port = 22
                        for p in active_pods:
                            if p.get("id") == sess.get("instance_id"):
                                _, ssh_port, _, _ = orch._extract_ip_and_ports(p)
                                break
                                
                        def _pair_and_clear(sid, target_ip, target_port, target_pin):
                            success = _pair_moonlight_pin(target_ip, target_port, target_pin)
                            if success:
                                # Limpiar el PIN de la base de datos
                                response = httpx.patch(
                                    f"{SUPABASE_URL}/rest/v1/sessions?id=eq.{sid}",
                                    json={"moonlight_pin": None},
                                    headers={
                                        "apikey": SUPABASE_KEY,
                                        "Authorization": f"Bearer {SUPABASE_KEY}",
                                        "Content-Type": "application/json"
                                    }
                                )
                                if response.status_code == 204:
                                    print(f"[*] PIN limpiado de la sesión {sid[:8]}.")
                        
                        threading.Thread(target=_pair_and_clear, args=(session_id, ip, ssh_port, pin), daemon=True).start()

        except Exception as e:
            print(f"[!] Error en el ciclo del daemon: {e}")
        
        await asyncio.sleep(5)

async def cleanup_pod(orch, session_id: str, pod_id: str):
    success = await orch.terminate_pod(pod_id)
    # Independientemente de si falló o no (podría no existir ya), limpiamos instance_id
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            await client.patch(
                f"{SUPABASE_URL}/rest/v1/sessions?id=eq.{session_id}",
                headers={
                    "apikey": SUPABASE_KEY,
                    "Authorization": f"Bearer {SUPABASE_KEY}",
                    "Content-Type": "application/json",
                    "Prefer": "return=minimal"
                },
                json={"instance_id": None}
            )
    except Exception as e:
        print(f"[!] Error limpiando instance_id de sesión {session_id}: {e}")

async def suspend_pod(orch, session_id: str, pod_id: str):
    success = await orch.stop_pod(pod_id)
    if success:
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                await client.patch(
                    f"{SUPABASE_URL}/rest/v1/sessions?id=eq.{session_id}",
                    headers={
                        "apikey": SUPABASE_KEY,
                        "Authorization": f"Bearer {SUPABASE_KEY}",
                        "Content-Type": "application/json",
                        "Prefer": "return=minimal"
                    },
                    json={"status": "sleeping", "status_message": "Máquina dormida. Esperando a ser reanudada."}
                )
        except Exception as e:
            print(f"[!] Error actualizando status a sleeping para sesión {session_id}: {e}")


if __name__ == "__main__":
    try:
        asyncio.run(orchestrator_daemon())
    except KeyboardInterrupt:
        print("\n[*] Orquestador detenido.")