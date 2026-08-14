import os
import base64
import requests
from dotenv import load_dotenv
from pathlib import Path

env_path = Path(__file__).parent / ".env"
load_dotenv(dotenv_path=env_path)

RUNPOD_API_KEY = os.getenv("RUNPOD_API_KEY")
SSH_KEY = os.getenv("SSH_KEY", "").strip('"')
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")
TAILSCALE_AUTHKEY = os.getenv("TAILSCALE_AUTHKEY")
STEAM_USERNAME = os.getenv("STEAM_USERNAME")
STEAM_PASSWORD = os.getenv("STEAM_PASSWORD")
VM_PASSWORD = os.getenv("VM_PASSWORD")

url = f"https://api.runpod.io/graphql?api_key={RUNPOD_API_KEY}"

# Leer y codificar el script de arranque en base64
script_path = Path(__file__).parent / "agent" / "vm_startup.sh"
with open(script_path, "r", encoding="utf-8") as f:
    STARTUP_SCRIPT = f.read()

STARTUP_B64 = base64.b64encode(STARTUP_SCRIPT.encode("utf-8")).decode("utf-8")

# El dockerArgs ejecutará el script al inicio del contenedor y luego lanzará supervisord
DOCKER_ARGS = f"""bash -c 'echo {STARTUP_B64} | base64 -d > /tmp/vm_startup.sh && chmod +x /tmp/vm_startup.sh && bash /tmp/vm_startup.sh && exec /usr/bin/supervisord -n -c /etc/supervisor.d/supervisord.ini'"""

def deploy():
    mutation = """
    mutation PodFindAndDeployOnDemand($input: PodFindAndDeployOnDemandInput!) {
      podFindAndDeployOnDemand(input: $input) {
        id
        imageName
        machineId
      }
    }
    """

    ports = "22/tcp,47984/tcp,47989/tcp,48010/tcp,47998/udp,47999/udp,48000/udp,48002/udp,48010/udp"

    gpus_to_try = [
        {"gpuTypeId": "NVIDIA GeForce RTX 3090", "cloudType": "COMMUNITY"},
        {"gpuTypeId": "NVIDIA GeForce RTX 3080", "cloudType": "COMMUNITY"},
        {"gpuTypeId": "NVIDIA RTX A4000", "cloudType": "SECURE"},
        {"gpuTypeId": "NVIDIA RTX A4000", "cloudType": "COMMUNITY"},
        {"gpuTypeId": "NVIDIA RTX A5000", "cloudType": "COMMUNITY"},
        {"gpuTypeId": "NVIDIA GeForce RTX 4090", "cloudType": "COMMUNITY"},
        {"gpuTypeId": "NVIDIA GeForce RTX 3070", "cloudType": "COMMUNITY"},
        {"gpuTypeId": "NVIDIA RTX 5000 Ada Generation", "cloudType": "COMMUNITY"},
    ]

    for gpu in gpus_to_try:
        variables = {
            "input": {
                "cloudType": gpu["cloudType"],
                "gpuCount": 1,
                "volumeInGb": 50,
                "containerDiskInGb": 50,
                "minVcpuCount": 4,
                "minMemoryInGb": 16,
                "gpuTypeId": gpu["gpuTypeId"],
                "name": "playstone-gaming-v2",
                # Imagen actualizada con nuestros fixes anti-EULA y Xorg
                "imageName": "ghcr.io/titoman81/playstone-gaming-base:v27",
                "dockerArgs": f"{DOCKER_ARGS}",
                "ports": ports,
                "volumeMountPath": "/workspace",
                "startSsh": True,
                "env": [
                    {"key": "PUBLIC_KEY", "value": SSH_KEY},
                    {"key": "NVIDIA_DRIVER_CAPABILITIES", "value": "all"},
                    {"key": "NVIDIA_VISIBLE_DEVICES", "value": "all"},
                    # Variables para el startup script
                    {"key": "SUPABASE_URL", "value": SUPABASE_URL},
                    {"key": "SUPABASE_KEY", "value": SUPABASE_KEY},
                    {"key": "TAILSCALE_AUTHKEY", "value": TAILSCALE_AUTHKEY},
                    {"key": "STEAM_USERNAME", "value": STEAM_USERNAME},
                    {"key": "STEAM_PASSWORD", "value": STEAM_PASSWORD},
                    {"key": "VM_PASSWORD", "value": VM_PASSWORD},
                    {"key": "STEAM_APP_ID", "value": "203140"},
                    # El startup script en base64 para ejecutarse en el init
                    {"key": "STARTUP_SCRIPT_B64", "value": STARTUP_B64},
                ]
            }
        }
        # Remove keys with None values
        variables["input"]["env"] = [e for e in variables["input"]["env"] if e["value"] is not None]

        print(f"[*] Intentando {gpu['cloudType']} / {gpu['gpuTypeId']}...")
        resp = requests.post(url, json={"query": mutation, "variables": variables})
        data = resp.json()

        if "errors" in data:
            print(f"    [-] Falló: {data['errors'][0]['message']}")
        else:
            pod = data["data"]["podFindAndDeployOnDemand"]
            print(f"    [+] ¡Pod creado! ID: {pod['id']}, Imagen: {pod['imageName']}")
            return pod["id"]

    return None

if __name__ == "__main__":
    pod_id = deploy()
    if pod_id:
        print(f"\n[OK] Nuevo pod (imagen cacheada): {pod_id}")
        print("[INFO] Deberia arrancar en ~30-60 segundos.")
        print("[INFO] Luego hay que lanzar el vm_startup.sh via SSH para instalar el escritorio.")
    else:
        print("[ERROR] No se pudo desplegar.")
