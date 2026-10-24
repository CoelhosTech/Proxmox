#!/usr/bin/env bash

# ==============================================================================
#
#  PROVISIONAMENTO DEBIAN 13 GENERICCLOUD
#  PROXMOX VE + CEPH RBD + HA
#
#  VMID.............: 900
#  NAME.............: srvAD01
#
#  CPU..............: 4 vCPU / host
#  RAM..............: 4096 MiB
#  BALLOONING.......: sim
#
#  DISK.............: 32 GB
#  STORAGE..........: Tank (Ceph/RBD)
#  CONTROLLER.......: VirtIO SCSI Single
#  DISCARD..........: sim
#  IOTHREAD.........: sim
#  SSD EMULATION....: sim
#
#  NETWORK..........: VirtIO
#  BRIDGE...........: vmbr0
#  MAC..............: BC:24:11:66:25:E3
#  FIREWALL.........: sim
#  IPv4.............: DHCP NATIVO DA IMAGEM
#
#  IMPORTANTE:
#    O script NAO configura rede dentro do Debian.
#    O script NAO cria Cloud-Init Drive.
#    O script NAO usa ipconfig0.
#    O script NAO cria/edita Netplan.
#    O script NAO cria/edita /etc/systemd/network.
#    O script NAO cria/edita /etc/network/interfaces.
#
#  MACHINE..........: q35
#  BIOS.............: OVMF / UEFI
#  EFI STORAGE......: Tank
#  TPM..............: Tank / TPM 2.0
#  CONSOLE..........: noVNC / Standard VGA
#
#  USUARIO..........: root
#  SENHA............: solicitada no terminal
#  SSH..............: root + senha habilitados
#  USUARIO DEBIAN...: removido
#
#  QEMU AGENT.......: instalado + validado
#  NOTES............: vazio
#  HA...............: sim
#
# ==============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit nullglob

# ==============================================================================
# CONFIGURACAO
# ==============================================================================

VMID="900"
NAME="srvAD01"

STORAGE="Tank"
LOCAL_STORAGE="local"

BRIDGE="vmbr0"
MAC="BC:24:11:66:25:E3"
MAC_LOWER="${MAC,,}"

CORES="4"
MEMORY="4096"
BALLOON="4096"
DISK_SIZE="32G"

IMAGE_NAME="debian-13-genericcloud-amd64.qcow2"
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/${IMAGE_NAME}"
CHECKSUM_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"

LOCAL_BASE="/var/lib/vz"
IMAGE_DIR="${LOCAL_BASE}/template/iso"
IMAGE_PATH="${IMAGE_DIR}/${IMAGE_NAME}"
DOWNLOAD_TMP="${IMAGE_PATH}.part"
WORK_IMAGE="${IMAGE_DIR}/.${VMID}-${NAME}-custom.qcow2"

SSH_CONFIG_HOST="/tmp/${VMID}-${NAME}-root-ssh.conf"
ROOT_PASSWORD_FILE="/tmp/${VMID}-${NAME}-root-password"
QGA_UDEV_HOST="/tmp/${VMID}-${NAME}-qemu-guest-agent.rules"

LOG_FILE="/var/log/criar-${NAME}.log"
CURRENT_STEP="Inicializacao"

# Tempos maximos de espera.
WAIT_VM_SECONDS=120
WAIT_AGENT_SECONDS=240
WAIT_DHCP_SECONDS=180
WAIT_SHUTDOWN_SECONDS=120
WAIT_HA_SECONDS=240

# ==============================================================================
# CORES
# ==============================================================================

RD='\033[01;31m'
YW='\033[33m'
GN='\033[1;92m'
BL='\033[1;94m'
CY='\033[1;96m'
CL='\033[m'
BFR='\r\033[K'

OK="${GN}✓${CL}"
ERROR="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"
WARN="${YW}⚠${CL}"

# ==============================================================================
# FUNCOES VISUAIS
# ==============================================================================

header_info() {
    clear
    echo
    echo -e "${BL}============================================================${CL}"
    echo -e "${BL} DEBIAN 13 GENERICCLOUD - PROXMOX VE${CL}"
    echo -e "${BL} VM ${VMID} - ${NAME}${CL}"
    echo -e "${BL}============================================================${CL}"
    echo
}

msg_info() {
    echo -ne " ${INFO} ${YW}$1...${CL}"
}

msg_ok() {
    echo -e "${BFR} ${OK} ${GN}$1${CL}"
}

msg_warn() {
    echo -e "${BFR} ${WARN} ${YW}$1${CL}"
}

msg_error() {
    echo -e "${BFR} ${ERROR} ${RD}$1${CL}" >&2
}

fail() {
    msg_error "$1"
    exit 1
}

show_log_error() {
    local RC="$1"

    echo
    echo -e "${RD}============================================================${CL}"
    echo -e "${RD} ERRO${CL}"
    echo -e "${RD}============================================================${CL}"
    echo
    printf ' %-13s %s\n' "ETAPA......." "$CURRENT_STEP"
    printf ' %-13s %s\n' "CODIGO......" "$RC"
    printf ' %-13s %s\n' "LOG........." "$LOG_FILE"
    echo
    echo -e "${YW}ULTIMAS LINHAS:${CL}"
    echo
    tail -n 40 "$LOG_FILE" 2>/dev/null || true
    echo
}

run_step() {
    local DESCRIPTION="$1"
    local RC
    shift

    CURRENT_STEP="$DESCRIPTION"
    msg_info "$DESCRIPTION"

    if "$@" >>"$LOG_FILE" 2>&1; then
        msg_ok "$DESCRIPTION"
        return 0
    else
        RC=$?
        msg_error "$DESCRIPTION"
        show_log_error "$RC"
        exit "$RC"
    fi
}

cleanup() {
    unset ROOT_PASSWORD ROOT_PASSWORD_CONFIRM 2>/dev/null || true

    rm -f "$DOWNLOAD_TMP" 2>/dev/null || true
    rm -f "$WORK_IMAGE" 2>/dev/null || true
    rm -f "$SSH_CONFIG_HOST" 2>/dev/null || true
    rm -f "$ROOT_PASSWORD_FILE" 2>/dev/null || true
    rm -f "$QGA_UDEV_HOST" 2>/dev/null || true
}

on_error() {
    local RC=$?
    local LINE="${1:-?}"

    echo
    msg_error "Erro inesperado"
    echo
    printf ' %-13s %s\n' "ETAPA......." "$CURRENT_STEP"
    printf ' %-13s %s\n' "CODIGO......" "$RC"
    printf ' %-13s %s\n' "LINHA......." "$LINE"
    printf ' %-13s %s\n' "LOG........." "$LOG_FILE"

    if [[ -f "$LOG_FILE" ]]; then
        echo
        echo -e "${YW}ULTIMAS LINHAS:${CL}"
        echo
        tail -n 40 "$LOG_FILE" || true
    fi

    echo
    exit "$RC"
}

trap cleanup EXIT
trap 'on_error $LINENO' ERR

# ==============================================================================
# FUNCOES DE ESPERA / GUEST
# ==============================================================================

wait_vm_running() {
    local elapsed=0
    local status

    while (( elapsed < WAIT_VM_SECONDS )); do
        status="$(qm status "$VMID" 2>/dev/null | awk '{print $2}' || true)"
        [[ "$status" == "running" ]] && return 0
        sleep 2
        ((elapsed+=2))
    done

    return 1
}

wait_vm_stopped() {
    local elapsed=0
    local status

    while (( elapsed < WAIT_SHUTDOWN_SECONDS )); do
        status="$(qm status "$VMID" 2>/dev/null | awk '{print $2}' || true)"
        [[ "$status" == "stopped" ]] && return 0
        sleep 2
        ((elapsed+=2))
    done

    return 1
}

wait_guest_agent() {
    local elapsed=0

    while (( elapsed < WAIT_AGENT_SECONDS )); do
        if qm agent "$VMID" ping >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        sleep 2
        ((elapsed+=2))
    done

    return 1
}

# Descobre a interface pelo MAC e verifica se ela recebeu IPv4 global.
# Nao configura, reinicia, renova ou altera a rede.
get_guest_ipv4() {
    local result
    local ip

    result="$(
        qm guest exec "$VMID" --timeout 30 -- /bin/bash -c "
MAC='${MAC_LOWER}'
IFACE=\$(ip -o link | awk -v mac=\"\$MAC\" '
    BEGIN { IGNORECASE=1 }
    {
        line=tolower(\$0)
        if (index(line, tolower(mac))) {
            iface=\$2
            sub(/:$/, \"\", iface)
            print iface
            exit
        }
    }
')

if [ -z \"\$IFACE\" ]; then
    echo 'NETWORK_ERROR=interface_nao_encontrada'
    exit 3
fi

echo \"INTERFACE=\$IFACE\"
IP=\$(ip -4 -o addr show dev \"\$IFACE\" scope global 2>/dev/null | awk 'NR==1 {print \$4}')

if [ -n \"\$IP\" ]; then
    echo \"IPV4=\$IP\"
    exit 0
fi

echo 'NETWORK_ERROR=sem_ipv4'
exit 4
" 2>>"$LOG_FILE" || true
    )"

    printf '%s\n' "$result" >>"$LOG_FILE"

    ip="$(printf '%s\n' "$result" | grep -oE 'IPV4=[0-9]+(\.[0-9]+){3}/[0-9]+' | head -n1 | cut -d= -f2 || true)"

    [[ -n "$ip" ]] || return 1
    printf '%s\n' "$ip"
}

wait_guest_ipv4() {
    local elapsed=0
    local ip

    while (( elapsed < WAIT_DHCP_SECONDS )); do
        ip="$(get_guest_ipv4 || true)"
        if [[ -n "$ip" ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
        sleep 3
        ((elapsed+=3))
    done

    return 1
}

# ==============================================================================
# INICIO
# ==============================================================================

header_info

: >"$LOG_FILE"
chmod 600 "$LOG_FILE"

cat >>"$LOG_FILE" <<EOF
============================================================
Provisionamento ${NAME}
VMID: ${VMID}
Inicio: $(date '+%Y-%m-%d %H:%M:%S')
============================================================

EOF

echo -e "${CY}Configuracao solicitada:${CL}"
echo
printf '  %-22s %s\n' "VMID:"          "$VMID"
printf '  %-22s %s\n' "Nome:"          "$NAME"
printf '  %-22s %s\n' "CPU:"           "${CORES} vCPU / host"
printf '  %-22s %s\n' "RAM:"           "${MEMORY} MiB"
printf '  %-22s %s\n' "Ballooning:"    "sim"
printf '  %-22s %s\n' "Disco:"         "$DISK_SIZE"
printf '  %-22s %s\n' "Storage:"       "$STORAGE"
printf '  %-22s %s\n' "Controller:"    "VirtIO SCSI Single"
printf '  %-22s %s\n' "Discard:"       "sim"
printf '  %-22s %s\n' "IOThread:"      "sim"
printf '  %-22s %s\n' "SSD Emulation:" "sim"
printf '  %-22s %s\n' "Rede:"          "VirtIO"
printf '  %-22s %s\n' "Bridge:"        "$BRIDGE"
printf '  %-22s %s\n' "MAC:"           "$MAC"
printf '  %-22s %s\n' "IPv4:"          "DHCP padrao da imagem"
printf '  %-22s %s\n' "Firewall:"      "sim"
printf '  %-22s %s\n' "Machine:"       "q35"
printf '  %-22s %s\n' "BIOS:"          "OVMF / UEFI"
printf '  %-22s %s\n' "EFI:"           "$STORAGE"
printf '  %-22s %s\n' "TPM:"           "${STORAGE} / TPM 2.0"
printf '  %-22s %s\n' "Console:"       "noVNC"
printf '  %-22s %s\n' "Usuario:"       "root"
printf '  %-22s %s\n' "SSH root:"      "senha habilitada"
printf '  %-22s %s\n' "Cloud-Init Drive:" "NAO criado"
printf '  %-22s %s\n' "QEMU Agent:"    "sim"
printf '  %-22s %s\n' "Notes:"         "vazio"
printf '  %-22s %s\n' "HA:"            "sim"
echo

# ==============================================================================
# ROOT
# ==============================================================================

CURRENT_STEP="Validando execucao como root"
[[ "$EUID" -eq 0 ]] || fail "Execute este script como root."
msg_ok "$CURRENT_STEP"

# ==============================================================================
# SENHA ROOT
# ==============================================================================

echo
echo -e "${CY}Senha do usuario root da nova VM:${CL}"
echo

while true; do
    read -rsp " Digite a senha do root: " ROOT_PASSWORD
    echo

    if [[ -z "$ROOT_PASSWORD" ]]; then
        msg_warn "A senha nao pode ficar vazia."
        echo
        continue
    fi

    if [[ ${#ROOT_PASSWORD} -lt 8 ]]; then
        msg_warn "Use pelo menos 8 caracteres."
        echo
        continue
    fi

    read -rsp " Confirme a senha.......: " ROOT_PASSWORD_CONFIRM
    echo

    if [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]]; then
        msg_warn "As senhas nao conferem."
        echo
        continue
    fi

    break
done

unset ROOT_PASSWORD_CONFIRM

# Guarda a senha em arquivo temporario protegido para o virt-customize.
umask 077
printf '%s\n' "$ROOT_PASSWORD" >"$ROOT_PASSWORD_FILE"
unset ROOT_PASSWORD
chmod 600 "$ROOT_PASSWORD_FILE"
msg_ok "Senha do root recebida"

# ==============================================================================
# FERRAMENTAS
# ==============================================================================

CURRENT_STEP="Validando ferramentas necessarias"

REQUIRED_COMMANDS=(
    qm
    pvesm
    pvecm
    pvesh
    ha-manager
    qemu-img
    wget
    sha512sum
    stat
    ip
    awk
    grep
    find
)

for CMD in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$CMD" >/dev/null 2>&1 || fail "Comando obrigatorio nao encontrado: ${CMD}"
done

msg_ok "$CURRENT_STEP"

# ==============================================================================
# LIBGUESTFS
# ==============================================================================

if ! command -v virt-customize >/dev/null 2>&1; then
    run_step "Atualizando lista de pacotes" apt-get update -qq
    run_step \
        "Instalando libguestfs-tools" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libguestfs-tools
else
    msg_ok "libguestfs-tools disponivel"
fi

command -v virt-customize >/dev/null 2>&1 || fail "virt-customize nao esta disponivel."

export LIBGUESTFS_BACKEND=direct
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# ==============================================================================
# STORAGE LOCAL
# ==============================================================================

CURRENT_STEP="Validando storage ${LOCAL_STORAGE}"

if ! pvesm status --storage "$LOCAL_STORAGE" 2>>"$LOG_FILE" |
    awk -v S="$LOCAL_STORAGE" '
        $1 == S && $2 == "dir" && $3 == "active" { OK=1 }
        END { exit !OK }
    '
then
    fail "Storage '${LOCAL_STORAGE}' nao esta ativo ou nao e DIR."
fi

msg_ok "Storage ${LOCAL_STORAGE} ativo"

# ==============================================================================
# STORAGE CEPH / RBD
# ==============================================================================

CURRENT_STEP="Validando storage ${STORAGE}"

if ! pvesm status --storage "$STORAGE" 2>>"$LOG_FILE" |
    awk -v S="$STORAGE" '
        $1 == S && $2 == "rbd" && $3 == "active" { OK=1 }
        END { exit !OK }
    '
then
    fail "Storage '${STORAGE}' nao esta ativo ou nao e RBD."
fi

msg_ok "Storage ${STORAGE} ativo"

# ==============================================================================
# BRIDGE
# ==============================================================================

CURRENT_STEP="Validando bridge ${BRIDGE}"
ip link show "$BRIDGE" >/dev/null 2>>"$LOG_FILE" || fail "Bridge '${BRIDGE}' nao encontrada."
msg_ok "Bridge ${BRIDGE} disponivel"

# ==============================================================================
# VMID - CLUSTER INTEIRO
# ==============================================================================

CURRENT_STEP="Validando VMID ${VMID}"

EXISTING_VM="$(
    find /etc/pve/nodes \
        -path "*/qemu-server/${VMID}.conf" \
        -print \
        -quit \
        2>/dev/null || true
)"

[[ -z "$EXISTING_VM" ]] || fail "VMID ${VMID} ja existe no cluster: ${EXISTING_VM}"
msg_ok "VMID ${VMID} disponivel"

# ==============================================================================
# MAC - DUPLICADO PERMITIDO APENAS SE A OUTRA VM ESTIVER DESLIGADA
# ==============================================================================

CURRENT_STEP="Validando MAC ${MAC}"
MAC_FOUND="no"

while IFS= read -r CONF; do
    [[ -f "$CONF" ]] || continue

    if grep -qi -- "$MAC" "$CONF"; then
        MAC_FOUND="yes"

        OLD_VMID="$(basename "$CONF" .conf)"
        OLD_NODE="$(echo "$CONF" | awk -F'/' '{print $5}')"

        msg_warn "MAC ${MAC} ja pertence a VM ${OLD_VMID} no node ${OLD_NODE}"

        OLD_STATUS="$(
            pvesh get "/nodes/${OLD_NODE}/qemu/${OLD_VMID}/status/current" \
                --output-format json 2>/dev/null |
                grep -o '"status":"[^"]*"' |
                cut -d'"' -f4 || true
        )"

        if [[ "$OLD_STATUS" == "running" ]]; then
            fail "A VM ${OLD_VMID} esta LIGADA usando o mesmo MAC ${MAC}."
        fi

        if [[ "$OLD_STATUS" == "stopped" ]]; then
            msg_ok "VM ${OLD_VMID} esta desligada; MAC duplicado permitido temporariamente"
        else
            fail "Nao foi possivel confirmar que a VM ${OLD_VMID} esta desligada."
        fi
    fi
done < <(
    find /etc/pve/nodes \
        -path "*/qemu-server/*.conf" \
        -type f \
        2>/dev/null
)

if [[ "$MAC_FOUND" == "no" ]]; then
    msg_ok "MAC ${MAC} disponivel"
fi

# ==============================================================================
# QUORUM / HA
# ==============================================================================

CURRENT_STEP="Validando quorum do cluster"
if ! pvecm status 2>>"$LOG_FILE" | grep -Eq '^Quorate:[[:space:]]+Yes$'; then
    fail "Cluster sem quorum. O provisionamento foi interrompido."
fi
msg_ok "Cluster com quorum"

CURRENT_STEP="Validando HA Manager"
ha-manager status >>"$LOG_FILE" 2>&1 || fail "HA Manager nao esta disponivel."
msg_ok "HA Manager disponivel"

if ha-manager config 2>/dev/null | grep -qE "(^|[[:space:]])vm:${VMID}([[:space:]]|$)"; then
    fail "O recurso HA vm:${VMID} ja existe."
fi

# ==============================================================================
# DIRETORIO / CHECKSUM
# ==============================================================================

CURRENT_STEP="Preparando diretorio da imagem"
mkdir -p "$IMAGE_DIR"
msg_ok "Diretorio de imagens preparado"

CURRENT_STEP="Obtendo SHA512 oficial"
msg_info "$CURRENT_STEP"

EXPECTED_SHA="$(
    wget -q --timeout=30 --tries=3 -O - "$CHECKSUM_URL" 2>>"$LOG_FILE" |
        awk -v F="$IMAGE_NAME" '
            $2 == F || $2 == "*" F { print $1; exit }
        '
)"

[[ -n "$EXPECTED_SHA" ]] || fail "Nao foi possivel obter o SHA512 oficial."
msg_ok "SHA512 oficial obtido"

# ==============================================================================
# IMAGEM EXISTENTE / DOWNLOAD
# ==============================================================================

DOWNLOAD_IMAGE="yes"

if [[ -s "$IMAGE_PATH" ]]; then
    CURRENT_STEP="Verificando imagem Debian 13 existente"
    msg_info "$CURRENT_STEP"

    EXISTING_SHA="$(sha512sum "$IMAGE_PATH" | awk '{print $1}')"

    if [[ "$EXISTING_SHA" == "$EXPECTED_SHA" ]]; then
        DOWNLOAD_IMAGE="no"
        IMAGE_SIZE_BYTES="$(stat -c%s "$IMAGE_PATH")"
        IMAGE_SIZE="$(awk -v B="$IMAGE_SIZE_BYTES" 'BEGIN { printf "%.1f MiB", B / 1024 / 1024 }')"
        msg_ok "Imagem Debian 13 ja disponivel (${IMAGE_SIZE})"
    else
        msg_warn "Imagem local desatualizada ou invalida; sera substituida"
        rm -f "$IMAGE_PATH"
    fi
fi

if [[ "$DOWNLOAD_IMAGE" == "yes" ]]; then
    CURRENT_STEP="Baixando Debian 13 GenericCloud"
    msg_info "$CURRENT_STEP"
    rm -f "$DOWNLOAD_TMP"

    if ! wget \
        -q \
        --timeout=30 \
        --tries=3 \
        --retry-connrefused \
        -O "$DOWNLOAD_TMP" \
        "$IMAGE_URL" \
        >>"$LOG_FILE" 2>&1
    then
        rm -f "$DOWNLOAD_TMP"
        fail "Falha ao baixar Debian 13 GenericCloud."
    fi

    [[ -s "$DOWNLOAD_TMP" ]] || fail "O arquivo baixado esta vazio."

    mv "$DOWNLOAD_TMP" "$IMAGE_PATH"

    IMAGE_SIZE_BYTES="$(stat -c%s "$IMAGE_PATH")"
    IMAGE_SIZE="$(awk -v B="$IMAGE_SIZE_BYTES" 'BEGIN { printf "%.1f MiB", B / 1024 / 1024 }')"
    msg_ok "Debian 13 GenericCloud baixado (${IMAGE_SIZE})"
fi

# ==============================================================================
# VALIDAR IMAGEM
# ==============================================================================

CURRENT_STEP="Validando SHA512 da imagem"
msg_info "$CURRENT_STEP"
ACTUAL_SHA="$(sha512sum "$IMAGE_PATH" | awk '{print $1}')"

if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    rm -f "$IMAGE_PATH"
    fail "SHA512 invalido. A imagem foi removida."
fi
msg_ok "SHA512 valido"

run_step "Validando estrutura QCOW2" qemu-img check "$IMAGE_PATH"

CURRENT_STEP="Criando copia temporaria da imagem"
msg_info "$CURRENT_STEP"
rm -f "$WORK_IMAGE"
cp --reflink=auto --sparse=always "$IMAGE_PATH" "$WORK_IMAGE"
msg_ok "Copia temporaria criada"

# ==============================================================================
# SSH ROOT / QEMU AGENT
#
# NENHUMA CONFIGURACAO DE REDE E CRIADA OU ALTERADA NESTA ETAPA.
# ==============================================================================

CURRENT_STEP="Preparando acesso SSH root"

cat >"$SSH_CONFIG_HOST" <<'EOF'
# Gerenciado automaticamente pelo provisionamento Proxmox
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF

cat >"$QGA_UDEV_HOST" <<'EOF'
SUBSYSTEM=="virtio-ports", ATTR{name}=="org.qemu.guest_agent.0", TAG+="systemd", ENV{SYSTEMD_WANTS}+="qemu-guest-agent.service"
EOF

chmod 600 "$SSH_CONFIG_HOST" "$QGA_UDEV_HOST"
msg_ok "$CURRENT_STEP"

run_step \
    "Personalizando Debian 13" \
    virt-customize \
        -a "$WORK_IMAGE" \
        --hostname "$NAME" \
        --install openssh-server,qemu-guest-agent \
        --password-crypto sha512 \
        --root-password "file:${ROOT_PASSWORD_FILE}" \
        --mkdir /etc/ssh/sshd_config.d \
        --mkdir /etc/udev/rules.d \
        --mkdir /etc/systemd/system-generators \
        --upload "${SSH_CONFIG_HOST}:/etc/ssh/sshd_config.d/00-root-password-login.conf" \
        --chmod '0644:/etc/ssh/sshd_config.d/00-root-password-login.conf' \
        --upload "${QGA_UDEV_HOST}:/etc/udev/rules.d/99-qemu-guest-agent.rules" \
        --chmod '0644:/etc/udev/rules.d/99-qemu-guest-agent.rules' \
        --run-command 'if id debian >/dev/null 2>&1; then userdel -r debian || true; fi' \
        --run-command 'rm -f /etc/ssh/ssh_host_*' \
        --run-command 'ssh-keygen -A' \
        --run-command 'install -d -m 0755 /run/sshd' \
        --run-command '/usr/sbin/sshd -t' \
        --run-command '/usr/sbin/sshd -T | grep -qx "permitrootlogin yes"' \
        --run-command '/usr/sbin/sshd -T | grep -qx "passwordauthentication yes"' \
        --run-command 'systemctl enable ssh.service >/dev/null 2>&1 || true' \
        --run-command 'ln -sf /dev/null /etc/systemd/system-generators/systemd-ssh-generator' \
        --run-command 'install -d /etc/systemd/system/multi-user.target.wants' \
        --run-command 'ln -sf /usr/lib/systemd/system/qemu-guest-agent.service /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service'

# A senha em texto claro nao e mais necessaria.
rm -f "$ROOT_PASSWORD_FILE"
rm -f "$SSH_CONFIG_HOST" "$QGA_UDEV_HOST"

run_step "Validando imagem personalizada" qemu-img check "$WORK_IMAGE"

# ==============================================================================
# CRIAR VM
# ==============================================================================

run_step \
    "Criando VM ${VMID} (${NAME})" \
    qm create "$VMID" \
        --name "$NAME" \
        --ostype l26 \
        --machine q35 \
        --bios ovmf \
        --cpu host \
        --sockets 1 \
        --cores "$CORES" \
        --memory "$MEMORY" \
        --balloon "$BALLOON" \
        --scsihw virtio-scsi-single \
        --net0 "virtio=${MAC},bridge=${BRIDGE},firewall=1" \
        --agent "enabled=1" \
        --vga std \
        --onboot 1

# ==============================================================================
# IMPORTAR / CONFIGURAR DISCO
# ==============================================================================

run_step \
    "Importando disco para ${STORAGE}" \
    qm disk import "$VMID" "$WORK_IMAGE" "$STORAGE" --format raw

CURRENT_STEP="Localizando disco importado"
IMPORTED_DISK="$(
    qm config "$VMID" |
        awk -F': ' '/^unused[0-9]+:/ { print $2; exit }'
)"

[[ -n "$IMPORTED_DISK" ]] || fail "Nao foi possivel localizar o disco importado."
msg_ok "Disco importado localizado"

run_step \
    "Configurando VirtIO SCSI" \
    qm set "$VMID" --scsi0 "${IMPORTED_DISK},discard=on,iothread=1,ssd=1"

run_step \
    "Configurando boot pelo SCSI0" \
    qm set "$VMID" --boot order=scsi0

run_step \
    "Redimensionando disco para ${DISK_SIZE}" \
    qm disk resize "$VMID" scsi0 "$DISK_SIZE"

run_step \
    "Criando EFI Disk no ${STORAGE}" \
    qm set "$VMID" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"

run_step \
    "Criando TPM 2.0 no ${STORAGE}" \
    qm set "$VMID" --tpmstate0 "${STORAGE}:1,version=v2.0"

# ==============================================================================
# VALIDAR HARDWARE ANTES DO PRIMEIRO BOOT
# ==============================================================================

CURRENT_STEP="Validando hardware inicial da VM"
VM_CONFIG="$(qm config "$VMID")"

printf '%s\n' "$VM_CONFIG" | grep -q '^bios: ovmf$' || fail "BIOS OVMF nao configurada."
printf '%s\n' "$VM_CONFIG" | grep -q '^machine: q35' || fail "Machine q35 nao configurada."
printf '%s\n' "$VM_CONFIG" | grep -q '^cpu: host' || fail "CPU type host nao configurado."
printf '%s\n' "$VM_CONFIG" | grep -q '^scsihw: virtio-scsi-single$' || fail "VirtIO SCSI Single nao configurado."
printf '%s\n' "$VM_CONFIG" | grep -q "^balloon: ${BALLOON}$" || fail "Ballooning nao configurado."
printf '%s\n' "$VM_CONFIG" | grep -qi "^net0: .*${MAC}.*bridge=${BRIDGE}.*firewall=1" || fail "NIC/MAC/bridge/firewall incorretos."
printf '%s\n' "$VM_CONFIG" | grep -q '^scsi0: .*discard=on.*iothread=1.*ssd=1' || fail "Flags do disco SCSI incorretas."
printf '%s\n' "$VM_CONFIG" | grep -q '^agent: enabled=1' || fail "QEMU Agent nao habilitado no Proxmox."
printf '%s\n' "$VM_CONFIG" | grep -q '^tpmstate0:' || fail "TPM 2.0 nao configurado."
printf '%s\n' "$VM_CONFIG" | grep -q '^efidisk0:' || fail "EFI Disk nao configurado."
printf '%s\n' "$VM_CONFIG" | grep -q '^vga: std$' || fail "Console noVNC/Standard VGA nao configurado."

if printf '%s\n' "$VM_CONFIG" | grep -q '^description:'; then
    fail "Notes/description nao deveria estar configurada."
fi

if printf '%s\n' "$VM_CONFIG" | grep -qi 'cloudinit'; then
    fail "Cloud-Init Drive nao deveria existir."
fi

if printf '%s\n' "$VM_CONFIG" | grep -Eq '^(ciuser|cipassword|ipconfig0|ciupgrade):'; then
    fail "Parametros Cloud-Init nao deveriam existir."
fi

if printf '%s\n' "$VM_CONFIG" | grep -q '^serial0:'; then
    fail "serial0 nao deveria existir; console deve ser noVNC."
fi

unset VM_CONFIG
msg_ok "Hardware inicial da VM validado"

# ==============================================================================
# PRIMEIRO BOOT - SEM HA
# ==============================================================================

run_step "Iniciando primeiro boot da VM" qm start "$VMID"

CURRENT_STEP="Aguardando VM iniciar"
msg_info "$CURRENT_STEP"
if wait_vm_running; then
    msg_ok "VM iniciada"
else
    fail "VM nao entrou em estado running dentro de ${WAIT_VM_SECONDS}s."
fi

CURRENT_STEP="Aguardando QEMU Guest Agent"
msg_info "$CURRENT_STEP"
if wait_guest_agent; then
    msg_ok "QEMU Guest Agent respondendo"
else
    fail "QEMU Guest Agent nao respondeu apos ${WAIT_AGENT_SECONDS}s. Consulte ${LOG_FILE}."
fi

# ==============================================================================
# VALIDAR ROOT / SSH / AGENT E REMOVER USUARIO DEBIAN SE O CLOUD-INIT O RECRIAR
# ==============================================================================

CURRENT_STEP="Validando sistema dentro da VM"
msg_info "$CURRENT_STEP"

GUEST_VALIDATE="$(
    qm guest exec "$VMID" --timeout 60 -- /bin/bash -c '
set -e

# Se a imagem/cloud-init recriou o usuario default, remove agora.
if id debian >/dev/null 2>&1; then
    userdel -r debian >/dev/null 2>&1 || true
fi

if id debian >/dev/null 2>&1; then
    echo "CHECK_DEBIAN=FAIL"
    exit 10
fi

echo "CHECK_DEBIAN=OK"

ROOT_STATE="$(passwd -S root | awk "{print \$2}")"
if [ "$ROOT_STATE" != "P" ]; then
    echo "CHECK_ROOT=FAIL:$ROOT_STATE"
    exit 11
fi

echo "CHECK_ROOT=OK"

if ! systemctl is-active --quiet qemu-guest-agent.service; then
    echo "CHECK_QGA=FAIL"
    systemctl status qemu-guest-agent.service --no-pager || true
    exit 12
fi

echo "CHECK_QGA=OK"

mkdir -p /run/sshd
if ! /usr/sbin/sshd -t; then
    echo "CHECK_SSHD=FAIL"
    exit 13
fi

if ! /usr/sbin/sshd -T | grep -qx "permitrootlogin yes"; then
    echo "CHECK_ROOT_SSH=FAIL"
    exit 14
fi

if ! /usr/sbin/sshd -T | grep -qx "passwordauthentication yes"; then
    echo "CHECK_PASSWORD_AUTH=FAIL"
    exit 15
fi

echo "CHECK_SSH=OK"
' 2>>"$LOG_FILE" || true
)"

printf '%s\n' "$GUEST_VALIDATE" >>"$LOG_FILE"

if ! printf '%s\n' "$GUEST_VALIDATE" | grep -q 'CHECK_DEBIAN=OK'; then
    fail "O usuario debian ainda existe dentro da VM."
fi

if ! printf '%s\n' "$GUEST_VALIDATE" | grep -q 'CHECK_ROOT=OK'; then
    fail "A conta root nao esta com senha ativa/desbloqueada."
fi

if ! printf '%s\n' "$GUEST_VALIDATE" | grep -q 'CHECK_QGA=OK'; then
    fail "qemu-guest-agent.service nao esta ativo dentro do Debian."
fi

if ! printf '%s\n' "$GUEST_VALIDATE" | grep -q 'CHECK_SSH=OK'; then
    fail "SSH root por senha nao ficou configurado corretamente."
fi

msg_ok "Root, SSH e QEMU Guest Agent validados"

# ==============================================================================
# VALIDAR DHCP NATIVO - SEM ALTERAR REDE
# ==============================================================================

CURRENT_STEP="Aguardando IPv4 via DHCP nativo da imagem"
msg_info "$CURRENT_STEP"

GUEST_IPV4="$(wait_guest_ipv4 || true)"

if [[ -z "$GUEST_IPV4" ]]; then
    {
        echo
        echo "===== DIAGNOSTICO DE REDE - SEM ALTERAR CONFIGURACAO ====="
        qm guest exec "$VMID" --timeout 30 -- /bin/bash -c '
            echo "=== ip -br link ==="
            ip -br link || true
            echo
            echo "=== ip -4 addr ==="
            ip -4 addr || true
            echo
            echo "=== rotas IPv4 ==="
            ip -4 route || true
            echo
            echo "=== /etc/network/interfaces ==="
            cat /etc/network/interfaces 2>/dev/null || true
            echo
            echo "=== /etc/netplan ==="
            find /etc/netplan -maxdepth 1 -type f -print -exec cat {} \; 2>/dev/null || true
            echo
            echo "=== /etc/systemd/network ==="
            find /etc/systemd/network -maxdepth 1 -type f -print -exec cat {} \; 2>/dev/null || true
        ' || true
    } >>"$LOG_FILE" 2>&1

    fail "A imagem nao recebeu IPv4 por DHCP sozinha apos ${WAIT_DHCP_SECONDS}s. Nenhuma configuracao de rede foi alterada. Consulte ${LOG_FILE}."
fi

msg_ok "IPv4 recebido por DHCP: ${GUEST_IPV4}"

# ==============================================================================
# DESLIGAR PRIMEIRO BOOT
# ==============================================================================

run_step "Desligando VM apos validacao inicial" qm shutdown "$VMID" --timeout 60

CURRENT_STEP="Aguardando desligamento da VM"
msg_info "$CURRENT_STEP"
if wait_vm_stopped; then
    msg_ok "VM desligada"
else
    fail "VM nao desligou corretamente dentro de ${WAIT_SHUTDOWN_SECONDS}s."
fi

# ==============================================================================
# VALIDACAO FINAL DA CONFIGURACAO PROXMOX ANTES DO HA
# ==============================================================================

CURRENT_STEP="Validando configuracao final da VM"
VM_CONFIG="$(qm config "$VMID")"

printf '%s\n' "$VM_CONFIG" | grep -q "^balloon: ${BALLOON}$" || fail "Ballooning nao esta habilitado."
printf '%s\n' "$VM_CONFIG" | grep -q '^vga: std$' || fail "Console nao esta em noVNC/Standard VGA."
printf '%s\n' "$VM_CONFIG" | grep -q '^scsi0: .*discard=on.*iothread=1.*ssd=1' || fail "Disco nao manteve SSD/Discard/IOThread."
printf '%s\n' "$VM_CONFIG" | grep -qi "^net0: .*${MAC}.*bridge=${BRIDGE}.*firewall=1" || fail "NIC final incorreta."
printf '%s\n' "$VM_CONFIG" | grep -q '^agent: enabled=1' || fail "QEMU Agent nao esta habilitado."

if printf '%s\n' "$VM_CONFIG" | grep -qi 'cloudinit'; then
    fail "Cloud-Init Drive apareceu indevidamente na configuracao."
fi

if printf '%s\n' "$VM_CONFIG" | grep -Eq '^(ciuser|cipassword|ipconfig0|ciupgrade):'; then
    fail "Parametros Cloud-Init apareceram indevidamente."
fi

if printf '%s\n' "$VM_CONFIG" | grep -q '^description:'; then
    fail "Notes/description nao deveria estar configurada."
fi

if printf '%s\n' "$VM_CONFIG" | grep -q '^serial0:'; then
    fail "serial0 nao deveria existir."
fi

unset VM_CONFIG
msg_ok "Configuracao final da VM validada"

# ==============================================================================
# HA
# ==============================================================================

run_step \
    "Adicionando VM ao HA" \
    ha-manager add "vm:${VMID}" --state started

CURRENT_STEP="Validando recurso HA"
if ! ha-manager config | grep -qE "(^|[[:space:]])vm:${VMID}([[:space:]]|$)"; then
    fail "VM criada, mas o recurso HA vm:${VMID} nao foi encontrado."
fi
msg_ok "Recurso HA vm:${VMID} configurado"

# ==============================================================================
# AGUARDAR BOOT DEFINITIVO PELO HA
# ==============================================================================

CURRENT_STEP="Aguardando inicializacao pelo HA"
msg_info "$CURRENT_STEP"

HA_ELAPSED=0
HA_RUNNING="no"

while (( HA_ELAPSED < WAIT_HA_SECONDS )); do
    STATUS="$(qm status "$VMID" 2>/dev/null | awk '{print $2}' || true)"
    if [[ "$STATUS" == "running" ]]; then
        HA_RUNNING="yes"
        break
    fi
    sleep 2
    ((HA_ELAPSED+=2))
done

[[ "$HA_RUNNING" == "yes" ]] || fail "HA nao iniciou a VM dentro de ${WAIT_HA_SECONDS}s."
msg_ok "VM iniciada pelo HA"

CURRENT_STEP="Validando QEMU Guest Agent apos boot definitivo"
msg_info "$CURRENT_STEP"
if wait_guest_agent; then
    msg_ok "QEMU Guest Agent ativo e respondendo"
else
    fail "VM iniciou pelo HA, mas o QEMU Guest Agent nao esta respondendo."
fi

CURRENT_STEP="Validando IPv4 apos boot definitivo"
msg_info "$CURRENT_STEP"
FINAL_IPV4="$(wait_guest_ipv4 || true)"

if [[ -z "$FINAL_IPV4" ]]; then
    fail "VM iniciou pelo HA, mas nao recebeu IPv4 por DHCP. Nenhuma configuracao de rede foi alterada."
fi
msg_ok "IPv4 ativo: ${FINAL_IPV4}"

# ==============================================================================
# RESULTADO FINAL
# ==============================================================================

echo
echo -e "${GN}============================================================${CL}"
echo -e "${GN} PROVISIONAMENTO CONCLUIDO${CL}"
echo -e "${GN}============================================================${CL}"
echo
printf '  %-25s %s\n' "VMID:"                "$VMID"
printf '  %-25s %s\n' "Nome:"                "$NAME"
echo
printf '  %-25s %s\n' "CPU:"                 "${CORES} vCPU"
printf '  %-25s %s\n' "CPU Type:"            "host"
printf '  %-25s %s\n' "RAM:"                 "${MEMORY} MiB"
printf '  %-25s %s\n' "Ballooning:"          "habilitado"
echo
printf '  %-25s %s\n' "Disco:"               "$DISK_SIZE"
printf '  %-25s %s\n' "Storage:"             "$STORAGE"
printf '  %-25s %s\n' "Controller:"          "VirtIO SCSI Single"
printf '  %-25s %s\n' "Discard:"             "ON"
printf '  %-25s %s\n' "IOThread:"            "ON"
printf '  %-25s %s\n' "SSD Emulation:"       "ON"
echo
printf '  %-25s %s\n' "Rede:"                "VirtIO"
printf '  %-25s %s\n' "Bridge:"              "$BRIDGE"
printf '  %-25s %s\n' "MAC:"                 "$MAC"
printf '  %-25s %s\n' "Firewall:"            "ON"
printf '  %-25s %s\n' "IPv4:"                "$FINAL_IPV4"
printf '  %-25s %s\n' "Config. rede script:" "NENHUMA"
echo
printf '  %-25s %s\n' "Machine:"             "q35"
printf '  %-25s %s\n' "BIOS:"                "OVMF / UEFI"
printf '  %-25s %s\n' "EFI Storage:"         "$STORAGE"
printf '  %-25s %s\n' "TPM:"                 "${STORAGE} / TPM 2.0"
printf '  %-25s %s\n' "Console:"             "noVNC / Standard VGA"
printf '  %-25s %s\n' "Notes:"               "vazio"
echo
printf '  %-25s %s\n' "Usuario:"             "root"
printf '  %-25s %s\n' "Usuario debian:"      "removido"
printf '  %-25s %s\n' "SSH root:"            "habilitado"
printf '  %-25s %s\n' "SSH por senha:"       "habilitado"
printf '  %-25s %s\n' "Cloud-Init Drive:"    "NAO criado"
printf '  %-25s %s\n' "QEMU Guest Agent:"    "ATIVO / RESPONDENDO"
echo
printf '  %-25s %s\n' "HA Resource:"         "vm:${VMID}"
printf '  %-25s %s\n' "HA Requested State:"  "started"
printf '  %-25s %s\n' "Log completo:"        "$LOG_FILE"

# ==============================================================================
# CONFIGURACAO EFETIVA
# ==============================================================================

echo
echo -e "${BL}============================================================${CL}"
echo -e "${BL} CONFIGURACAO EFETIVA DA VM${CL}"
echo -e "${BL}============================================================${CL}"
echo

qm config "$VMID" |
    grep -E '^(agent|balloon|bios|boot|cores|cpu|efidisk0|machine|memory|name|net0|scsi0|scsihw|tpmstate0|vga):'

# ==============================================================================
# HA STATUS
# ==============================================================================

echo
echo -e "${BL}============================================================${CL}"
echo -e "${BL} ESTADO HA${CL}"
echo -e "${BL}============================================================${CL}"
echo

ha-manager status |
    grep -E "(^quorum|^master|vm:${VMID})" || true

# ==============================================================================
# ACESSO
# ==============================================================================

echo
echo -e "${BL}============================================================${CL}"
echo -e "${BL} ACESSO AO DEBIAN${CL}"
echo -e "${BL}============================================================${CL}"
echo
echo -e " Usuario: ${GN}root${CL}"
echo -e " IPv4...: ${GN}${FINAL_IPV4}${CL}"
echo
SSH_IP="${FINAL_IPV4%%/*}"
echo -e "   ${BL}ssh root@${SSH_IP}${CL}"
echo
echo -e "${GN}Provisionamento finalizado com sucesso.${CL}"
echo

cat >>"$LOG_FILE" <<EOF

============================================================
Provisionamento concluido
IPv4 final: ${FINAL_IPV4}
Fim: $(date '+%Y-%m-%d %H:%M:%S')
============================================================
EOF
