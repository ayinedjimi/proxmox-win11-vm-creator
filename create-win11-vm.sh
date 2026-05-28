#!/usr/bin/env bash
# ============================================================================
#  create-win11-vm.sh — Création d'une VM Windows 11 fonctionnelle sur
#                       Proxmox VE 9 en environnement nested Hyper-V
#
#  Différences avec l'atelier standard :
#    • BIOS SeaBIOS (pas OVMF — OVMF est cassé en nested Hyper-V)
#    • Pas d'EFI Disk, pas de TPM (inutiles sans OVMF)
#    • Bypass TPM/SecureBoot à l'install via reg add (cf. doc)
#
#  (c) 2026 Ayi NEDJIMI Consultants
# ============================================================================

set -euo pipefail

# ---------- Valeurs par défaut (peuvent être surchargées par variables d'env) ----------
: "${VMID:=200}"
: "${NAME:=windows11}"
: "${WIN_ISO:=Win11_25H2_French_x64_v2.iso}"
: "${VIRTIO_ISO:=}"                       # auto-détecté si vide
: "${ISO_STORAGE:=local}"
: "${DISK_STORAGE:=local-lvm}"
: "${DISK_SIZE:=64}"
: "${CORES:=4}"
: "${SOCKETS:=1}"
: "${CPU_TYPE:=host}"
: "${MEMORY:=4096}"
: "${BRIDGE:=vmbr0}"

# ---------- Couleurs ----------
if [ -t 1 ]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi
ok()   { echo "${C_GRN}[ OK ]${C_RST} $*"; }
warn() { echo "${C_YEL}[WARN]${C_RST} $*"; }
err()  { echo "${C_RED}[ERR ]${C_RST} $*" >&2; }
step() { echo; echo "${C_BLD}${C_BLU}━━━ $* ━━━${C_RST}"; }

# ---------- Pré-requis ----------
[ "$(id -u)" -eq 0 ] || { err "Ce script doit être lancé en root"; exit 1; }
command -v qm    >/dev/null || { err "qm introuvable — ce n'est pas un nœud Proxmox VE"; exit 1; }
command -v pvesm >/dev/null || { err "pvesm introuvable"; exit 1; }

NODE=$(hostname)

step "Configuration"
cat <<EOF
  VMID            : ${VMID}
  Nom             : ${NAME}
  Nœud            : ${NODE}
  ISO Windows     : ${WIN_ISO}
  ISO storage     : ${ISO_STORAGE}
  Disque storage  : ${DISK_STORAGE}
  Taille disque   : ${DISK_SIZE} Go
  CPU             : ${CORES} cores × ${SOCKETS} socket(s) (type ${CPU_TYPE})
  Mémoire         : ${MEMORY} Mo
  Bridge réseau   : ${BRIDGE}
EOF

# ---------- 1. Vérification VMID libre ----------
step "1. Vérification VMID"
if qm status "${VMID}" >/dev/null 2>&1; then
    err "VMID ${VMID} déjà utilisé. Choisis un autre VMID :"
    err "  VMID=203 bash $0"
    qm list | head -20
    exit 1
fi
ok "VMID ${VMID} libre"

# ---------- 2. Détection ISO VirtIO ----------
step "2. Détection ISO VirtIO"
if [ -z "${VIRTIO_ISO}" ]; then
    VIRTIO_ISO=$(pvesm list "${ISO_STORAGE}" --content iso 2>/dev/null \
        | awk '/virtio-win/ {n=$1; sub(".*/","",n); print n; exit}')
fi
if [ -z "${VIRTIO_ISO}" ]; then
    err "Aucune ISO VirtIO trouvée sur ${ISO_STORAGE}."
    err "Télécharge-la depuis :"
    err "  https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    err "Ou via Proxmox :"
    err "  pvesh create /nodes/${NODE}/storage/${ISO_STORAGE}/download-url \\"
    err "    --url https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso \\"
    err "    --content iso --filename virtio-win.iso"
    exit 1
fi
ok "ISO VirtIO : ${VIRTIO_ISO}"

# ---------- 3. Vérification ISO Windows ----------
step "3. Vérification ISO Windows"
if ! pvesm list "${ISO_STORAGE}" --content iso 2>/dev/null | grep -qF "/${WIN_ISO}"; then
    err "ISO Windows '${WIN_ISO}' introuvable sur ${ISO_STORAGE}"
    err "Liste des ISO disponibles :"
    pvesm list "${ISO_STORAGE}" --content iso 2>&1 | sed 's/^/  /'
    err "Upload-la via la GUI (Datacenter → ${ISO_STORAGE} → ISO Images → Upload)"
    err "ou via scp : scp /chemin/${WIN_ISO} root@${NODE}:/var/lib/vz/template/iso/"
    exit 1
fi
ok "ISO Windows présente : ${WIN_ISO}"

# ---------- 4. Création de la VM ----------
step "4. Création VM ${VMID}"
qm create "${VMID}" \
    --name        "${NAME}" \
    --ostype      win11 \
    --bios        seabios \
    --machine     q35 \
    --cores       "${CORES}" \
    --sockets     "${SOCKETS}" \
    --cpu         "${CPU_TYPE}" \
    --memory      "${MEMORY}" \
    --balloon     0 \
    --scsihw      virtio-scsi-single \
    --scsi0       "${DISK_STORAGE}:${DISK_SIZE},cache=writeback,discard=on,iothread=1,ssd=1" \
    --ide0        "${ISO_STORAGE}:iso/${WIN_ISO},media=cdrom" \
    --ide1        "${ISO_STORAGE}:iso/${VIRTIO_ISO},media=cdrom" \
    --net0        "virtio,bridge=${BRIDGE},firewall=1" \
    --agent       enabled=1 \
    --tablet      1 \
    --vga         std \
    --boot        'order=ide0;scsi0;net0' \
    --tags        "windows;win11;auto-created" \
    >/dev/null
ok "VM ${VMID} (${NAME}) créée"

# ---------- 5. Démarrage ----------
step "5. Démarrage VM"
qm start "${VMID}" >/dev/null
ok "VM ${VMID} démarrée"

echo
echo "${C_BLD}Ouvre la console et presse ESPACE rapidement pour booter sur le CD :${C_RST}"
echo "  https://${NODE}:8006  →  VM ${VMID}  →  Console"
