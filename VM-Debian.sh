#!/usr/bin/env bash

# ==============================================================================
#
#  PROVISIONAMENTO DEBIAN 13 GENERICCLOUD
#  PROXMOX VE + CEPH RBD + CLOUD-INIT + HA
#
#  VMID.............: 900
#  NAME.............: srvAD01
#
#  CPU..............: 4 vCPU
#  CPU TYPE.........: host
#  RAM..............: 4096 MiB
#
#  DISK.............: 32 GB
#  STORAGE..........: Tank (Ceph/RBD)
#  CONTROLLER.......: VirtIO SCSI Single
#  DISCARD..........: sim
#  IOTHREAD.........: sim
#
#  NETWORK..........: VirtIO
#  BRIDGE...........: vmbr0
#  MAC..............: BC:24:11:66:25:E3
#  IPv4.............: DHCP
#
#  MACHINE..........: q35
#  BIOS.............: OVMF / UEFI
#  EFI STORAGE......: Tank
#  TPM..............: Tank / TPM 2.0
#
#  CLOUD-INIT.......: sim
#  USUARIO..........: root
#  SENHA............: solicitada no terminal
#
#  SSH..............: root + senha habilitados
#  USUARIO DEBIAN...: removido
#
#  QEMU AGENT.......: instalado + habilitado
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
="BC:24:11:66:25:E3"

CORES="4"
MEMORY="4096"
DISK_SIZE="32G"

IMAGE_NAME="debian-13-genericcloud-amd64.qcow2"

IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/${IMAGE_NAME}"
CHECKSUM_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"

LOCAL_BASE="/var/lib/vz"
IMAGE_DIR="${LOCAL_BASE}/template/iso"

IMAGE_PATH="${IMAGE_DIR}/${IMAGE_NAME}"
DOWNLOAD_TMP="${IMAGE_PATH}.part"

# Imagem temporaria usada para personalizacao.
WORK_IMAGE="${IMAGE_DIR}/.${VMID}-${NAME}-custom.qcow2"

# Arquivo temporario de configuracao SSH.
SSH_CONFIG_HOST="/tmp/${VMID}-${NAME}-root-ssh.conf"

# Log detalhado.
LOG_FILE="/var/log/criar-${NAME}.log"

CURRENT_STEP="Inicializacao"

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

# ==============================================================================
# MOSTRAR ERRO DO LOG
# ==============================================================================

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

    tail -n 30 "$LOG_FILE" 2>/dev/null || true

    echo
}

# ==============================================================================
# EXECUTAR COMANDO SILENCIOSAMENTE
#
# Todo stdout/stderr vai para LOG_FILE.
# No terminal aparece apenas:
#
#   ℹ Executando...
#   ✓ Executando
#
# ==============================================================================

run_step() {

    local DESCRIPTION="$1"
    shift

    CURRENT_STEP="$DESCRIPTION"

    msg_info "$DESCRIPTION"

    set +e

    "$@" >>"$LOG_FILE" 2>&1

    local RC=$?

    set -e

    if [[ "$RC" -eq 0 ]]; then

        msg_ok "$DESCRIPTION"

        return 0
    fi

    msg_error "$DESCRIPTION"

    show_log_error "$RC"

    exit "$RC"
}

# ==============================================================================
# CLEANUP
# ==============================================================================

cleanup() {

    unset ROOT_PASSWORD 2>/dev/null || true
    unset ROOT_PASSWORD_CONFIRM 2>/dev/null || true
    unset ROOT_PASSWORD_HASH 2>/dev/null || true

    rm -f "$DOWNLOAD_TMP" 2>/dev/null || true
    rm -f "$WORK_IMAGE" 2>/dev/null || true
    rm -f "$SSH_CONFIG_HOST" 2>/dev/null || true
}

trap cleanup EXIT

# ==============================================================================
# ERRO NAO TRATADO
# ==============================================================================

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

        tail -n 30 "$LOG_FILE" || true
    fi

    echo

    exit "$RC"
}

trap 'on_error $LINENO' ERR

# ==============================================================================
# CABECALHO
# ==============================================================================

header_info

# Limpa log anterior.
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

printf '  %-21s %s\n' "VMID:"       "$VMID"
printf '  %-21s %s\n' "Nome:"       "$NAME"
printf '  %-21s %s\n' "CPU:"        "${CORES} vCPU / host"
printf '  %-21s %s\n' "RAM:"        "${MEMORY} MiB"
printf '  %-21s %s\n' "Disco:"      "$DISK_SIZE"
printf '  %-21s %s\n' "Storage:"    "$STORAGE"
printf '  %-21s %s\n' "Controller:" "VirtIO SCSI Single"
printf '  %-21s %s\n' "Discard:"    "sim"
printf '  %-21s %s\n' "IOThread:"   "sim"
printf '  %-21s %s\n' "Rede:"       "VirtIO"
printf '  %-21s %s\n' "Bridge:"     "$BRIDGE"
printf '  %-21s %s\n' ":"        "$"
printf '  %-21s %s\n' "IPv4:"       "DHCP"
printf '  %-21s %s\n' "hine:"    "q35"
printf '  %-21s %s\n' "BIOS:"       "OVMF / UEFI"
printf '  %-21s %s\n' "EFI:"        "$STORAGE"
printf '  %-21s %s\n' "TPM:"        "${STORAGE} / TPM 2.0"
printf '  %-21s %s\n' "Usuario:"    "root"
printf '  %-21s %s\n' "SSH root:"   "senha habilitada"
printf '  %-21s %s\n' "QEMU Agent:" "sim"
printf '  %-21s %s\n' "HA:"         "sim"

echo

# ==============================================================================
# ROOT
# ==============================================================================

CURRENT_STEP="Validando execucao como root"

[[ "$EUID" -eq 0 ]] \
    || fail "Execute este script como root."

msg_ok "$CURRENT_STEP"

# ==============================================================================
# SOLICITAR SENHA ROOT
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

msg_ok "Senha do root recebida"

# ==============================================================================
# FERRAMENTAS BASICAS
# ==============================================================================

CURRENT_STEP="Validando ferramentas necessarias"

REQUIRED_COMMANDS=(
    qm
    pvesm
    pvecm
    ha-manager
    qemu-img
    wget
    sha512sum
    openssl
    stat
    ip
    awk
    grep
    find
)

for CMD in "${REQUIRED_COMMANDS[@]}"; do

    command -v "$CMD" >/dev/null 2>&1 \
        || fail "Comando obrigatorio nao encontrado: ${CMD}"
done

msg_ok "$CURRENT_STEP"

# ==============================================================================
# HASH DA SENHA
# ==============================================================================

CURRENT_STEP="Protegendo senha do root"

ROOT_PASSWORD_HASH="$(
    printf '%s' "$ROOT_PASSWORD" |
        openssl passwd -6 -stdin
)"

[[ -n "$ROOT_PASSWORD_HASH" ]] \
    || fail "Nao foi possivel gerar o hash da senha."

unset ROOT_PASSWORD

msg_ok "$CURRENT_STEP"

# ==============================================================================
# LIBGUESTFS
# ==============================================================================

if ! command -v virt-customize >/dev/null 2>&1; then

    run_step \
        "Atualizando lista de pacotes" \
        apt-get update -qq

    run_step \
        "Instalando libguestfs-tools" \
        env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq libguestfs-tools
else

    msg_ok "libguestfs-tools disponivel"
fi

command -v virt-customize >/dev/null 2>&1 \
    || fail "virt-customize nao esta disponivel."

# Backend mais previsivel em hosts Proxmox.
export LIBGUESTFS_BACKEND=direct

# Evita output de progresso de algumas ferramentas.
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# ==============================================================================
# STORAGE LOCAL
# ==============================================================================

CURRENT_STEP="Validando storage ${LOCAL_STORAGE}"

if ! pvesm status --storage "$LOCAL_STORAGE" 2>>"$LOG_FILE" |
    awk -v S="$LOCAL_STORAGE" '
        $1 == S && $2 == "dir" && $3 == "active" {
            OK=1
        }

        END {
            exit !OK
        }
    '
then
    fail "Storage '${LOCAL_STORAGE}' nao esta ativo ou nao e DIR."
fi

msg_ok "Storage ${LOCAL_STORAGE} ativo"

# ==============================================================================
# STORAGE CEPH RBD
# ==============================================================================

CURRENT_STEP="Validando storage ${STORAGE}"

if ! pvesm status --storage "$STORAGE" 2>>"$LOG_FILE" |
    awk -v S="$STORAGE" '
        $1 == S && $2 == "rbd" && $3 == "active" {
            OK=1
        }

        END {
            exit !OK
        }
    '
then
    fail "Storage '${STORAGE}' nao esta ativo ou nao e RBD."
fi

msg_ok "Storage ${STORAGE} ativo"

# ==============================================================================
# BRIDGE
# ==============================================================================

CURRENT_STEP="Validando bridge ${BRIDGE}"

ip link show "$BRIDGE" >/dev/null 2>>"$LOG_FILE" \
    || fail "Bridge '${BRIDGE}' nao encontrada."

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

if [[ -n "$EXISTING_VM" ]]; then

    fail "VMID ${VMID} ja existe no cluster: ${EXISTING_VM}"
fi

msg_ok "VMID ${VMID} disponivel"

# ==============================================================================
# MAC - CLUSTER INTEIRO
#
# MAC duplicado e permitido se a VM que ja o utiliza estiver DESLIGADA.
# Se estiver LIGADA, o provisionamento e interrompido.
# ==============================================================================

CURRENT_STEP="Validando MAC ${MAC}"

MAC_FOUND="no"

while IFS= read -r CONF; do

    [[ -f "$CONF" ]] || continue

    if grep -qi -- "$MAC" "$CONF"; then

        MAC_FOUND="yes"

        OLD_VMID="$(
            basename "$CONF" .conf
        )"

        OLD_NODE="$(
            echo "$CONF" |
                awk -F'/' '{print $5}'
        )"

        msg_warn "MAC ${MAC} ja pertence a VM ${OLD_VMID} no node ${OLD_NODE}"

        OLD_STATUS="$(
            pvesh get "/nodes/${OLD_NODE}/qemu/${OLD_VMID}/status/current" \
                --output-format json 2>/dev/null |
            grep -o '"status":"[^"]*"' |
            cut -d'"' -f4
        )"

        if [[ "$OLD_STATUS" == "running" ]]; then

            fail "A VM ${OLD_VMID} esta LIGADA usando o mesmo MAC ${MAC}."

        fi

        msg_ok "VM ${OLD_VMID} esta desligada; MAC duplicado permitido temporariamente"

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
# QUORUM
# ==============================================================================

CURRENT_STEP="Validando quorum do cluster"

if ! pvecm status 2>>"$LOG_FILE" |
    grep -Eq '^Quorate:[[:space:]]+Yes$'
then
    fail "Cluster sem quorum. O provisionamento foi interrompido."
fi

msg_ok "Cluster com quorum"

# ==============================================================================
# HA
# ==============================================================================

CURRENT_STEP="Validando HA Manager"

ha-manager status >>"$LOG_FILE" 2>&1 \
    || fail "HA Manager nao esta disponivel."

msg_ok "HA Manager disponivel"

if ha-manager config 2>/dev/null |
    grep -qE "(^|[[:space:]])vm:${VMID}([[:space:]]|$)"
then
    fail "O recurso HA vm:${VMID} ja existe."
fi

# ==============================================================================
# DIRETORIO DA IMAGEM
# ==============================================================================

CURRENT_STEP="Preparando diretorio da imagem"

mkdir -p "$IMAGE_DIR"

msg_ok "Diretorio de imagens preparado"

# ==============================================================================
# OBTER SHA512 OFICIAL
# ==============================================================================

CURRENT_STEP="Obtendo SHA512 oficial"

msg_info "$CURRENT_STEP"

set +e

EXPECTED_SHA="$(
    wget \
        -q \
        --timeout=30 \
        --tries=3 \
        -O - \
        "$CHECKSUM_URL" 2>>"$LOG_FILE" |
        awk -v F="$IMAGE_NAME" '
            $2 == F || $2 == "*" F {
                print $1
                exit
            }
        '
)"

RC=$?

set -e

if [[ "$RC" -ne 0 || -z "$EXPECTED_SHA" ]]; then

    fail "Nao foi possivel obter o SHA512 oficial."
fi

msg_ok "SHA512 oficial obtido"

# ==============================================================================
# VERIFICAR IMAGEM EXISTENTE
# ==============================================================================

DOWNLOAD_IMAGE="yes"

if [[ -s "$IMAGE_PATH" ]]; then

    CURRENT_STEP="Verificando imagem Debian 13 existente"

    msg_info "$CURRENT_STEP"

    EXISTING_SHA="$(
        sha512sum "$IMAGE_PATH" |
            awk '{print $1}'
    )"

    if [[ "$EXISTING_SHA" == "$EXPECTED_SHA" ]]; then

        DOWNLOAD_IMAGE="no"

        IMAGE_SIZE_BYTES="$(stat -c%s "$IMAGE_PATH")"

        IMAGE_SIZE="$(
            awk -v B="$IMAGE_SIZE_BYTES" '
                BEGIN {
                    printf "%.1f MiB", B / 1024 / 1024
                }
            '
        )"

        msg_ok "Imagem Debian 13 ja disponivel (${IMAGE_SIZE})"
    else

        msg_warn "Imagem local desatualizada ou invalida; sera substituida"

        rm -f "$IMAGE_PATH"
    fi
fi

# ==============================================================================
# DOWNLOAD
# ==============================================================================

if [[ "$DOWNLOAD_IMAGE" == "yes" ]]; then

    CURRENT_STEP="Baixando Debian 13 GenericCloud"

    msg_info "$CURRENT_STEP"

    rm -f "$DOWNLOAD_TMP"

    set +e

    wget \
        -q \
        --timeout=30 \
        --tries=3 \
        --retry-connrefused \
        -O "$DOWNLOAD_TMP" \
        "$IMAGE_URL" \
        >>"$LOG_FILE" 2>&1

    RC=$?

    set -e

    if [[ "$RC" -ne 0 ]]; then

        rm -f "$DOWNLOAD_TMP"

        fail "Falha ao baixar Debian 13 GenericCloud."
    fi

    [[ -s "$DOWNLOAD_TMP" ]] \
        || fail "O arquivo baixado esta vazio."

    mv "$DOWNLOAD_TMP" "$IMAGE_PATH"

    IMAGE_SIZE_BYTES="$(stat -c%s "$IMAGE_PATH")"

    IMAGE_SIZE="$(
        awk -v B="$IMAGE_SIZE_BYTES" '
            BEGIN {
                printf "%.1f MiB", B / 1024 / 1024
            }
        '
    )"

    msg_ok "Debian 13 GenericCloud baixado (${IMAGE_SIZE})"
fi

# ==============================================================================
# VALIDAR SHA512
# ==============================================================================

CURRENT_STEP="Validando SHA512 da imagem"

msg_info "$CURRENT_STEP"

ACTUAL_SHA="$(
    sha512sum "$IMAGE_PATH" |
        awk '{print $1}'
)"

if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then

    rm -f "$IMAGE_PATH"

    fail "SHA512 invalido. A imagem foi removida."
fi

msg_ok "SHA512 valido"

# ==============================================================================
# VALIDAR QCOW2
# ==============================================================================

run_step \
    "Validando estrutura QCOW2" \
    qemu-img check "$IMAGE_PATH"

# ==============================================================================
# CRIAR COPIA DE TRABALHO
# ==============================================================================

CURRENT_STEP="Criando copia temporaria da imagem"

msg_info "$CURRENT_STEP"

rm -f "$WORK_IMAGE"

cp \
    --reflink=auto \
    --sparse=always \
    "$IMAGE_PATH" \
    "$WORK_IMAGE"

msg_ok "Copia temporaria criada"

# ==============================================================================
# CRIAR CONFIGURACAO SSH
#
# Prefixo 00- garante precedencia sobre configuracoes posteriores do
# cloud-init em /etc/ssh/sshd_config.d/.
#
# ==============================================================================

CURRENT_STEP="Preparando acesso SSH root"

cat >"$SSH_CONFIG_HOST" <<'EOF'
# =============================================================================
# Gerenciado automaticamente pelo provisionamento Proxmox
# =============================================================================

PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF

chmod 600 "$SSH_CONFIG_HOST"

msg_ok "$CURRENT_STEP"

# ==============================================================================
# PERSONALIZAR IMAGEM
#
# IMPORTANTE:
#
# A imagem Debian GenericCloud pode nao possuir:
#
#   /etc/ssh/ssh_host_rsa_key
#   /etc/ssh/ssh_host_ecdsa_key
#   /etc/ssh/ssh_host_ed25519_key
#
# Nesse caso:
#
#   sshd -t
#
# retorna:
#
#   sshd: no hostkeys available -- exiting.
#
# Por isso geramos as host keys ANTES de validar sshd.
#
# Todo o output do virt-customize vai SOMENTE para:
#
#   /var/log/criar-srvAD01.log
#
# ==============================================================================

run_step \
    "Personalizando Debian 13" \
    virt-customize \
        -a "$WORK_IMAGE" \
        --install openssh-server,qemu-guest-agent \
        --mkdir /etc/ssh/sshd_config.d \
        --upload "${SSH_CONFIG_HOST}:/etc/ssh/sshd_config.d/00-root-password-login.conf" \
        --chmod '0644:/etc/ssh/sshd_config.d/00-root-password-login.conf' \
        --run-command 'if id debian >/dev/null 2>&1; then userdel -r debian || true; fi' \
        --run-command 'systemctl enable ssh.service >/dev/null 2>&1 || true' \
        --run-command 'systemctl enable qemu-guest-agent.service >/dev/null 2>&1 || true' \
        --run-command 'rm -f /etc/ssh/ssh_host_*' \
        --run-command 'ssh-keygen -A' \
        --run-command '/usr/sbin/sshd -t' \
        --run-command '/usr/sbin/sshd -T | grep -qx "permitrootlogin yes"' \
        --run-command '/usr/sbin/sshd -T | grep -qx "passwordauthentication yes"'

# ==============================================================================
# VALIDAR IMAGEM CUSTOMIZADA
# ==============================================================================

run_step \
    "Validando imagem personalizada" \
    qemu-img check "$WORK_IMAGE"

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
        --balloon 0 \
        --scsihw virtio-scsi-single \
        --net0 "virtio=${MAC},bridge=${BRIDGE}" \
        --agent "enabled=1" \
        --serial0 socket \
        --vga serial0 \
        --onboot 1 \
        --description "Debian 13 Trixie GenericCloud | ${NAME} | Ceph RBD | HA"

# ==============================================================================
# IMPORTAR DISCO PARA CEPH
# ==============================================================================

run_step \
    "Importando disco para ${STORAGE}" \
    qm disk import \
        "$VMID" \
        "$WORK_IMAGE" \
        "$STORAGE" \
        --format raw

# ==============================================================================
# LOCALIZAR DISCO IMPORTADO
# ==============================================================================

CURRENT_STEP="Localizando disco importado"

IMPORTED_DISK="$(
    qm config "$VMID" |
        awk -F': ' '
            /^unused[0-9]+:/ {
                print $2
                exit
            }
        '
)"

[[ -n "$IMPORTED_DISK" ]] \
    || fail "Nao foi possivel localizar o disco importado."

msg_ok "Disco importado localizado"

# ==============================================================================
# CONFIGURAR SCSI0
# ==============================================================================

run_step \
    "Configurando VirtIO SCSI" \
    qm set "$VMID" \
        --scsi0 "${IMPORTED_DISK},discard=on,iothread=1"

# ==============================================================================
# BOOT
# ==============================================================================

run_step \
    "Configurando boot pelo SCSI0" \
    qm set "$VMID" \
        --boot order=scsi0

# ==============================================================================
# REDIMENSIONAR DISCO
# ==============================================================================

run_step \
    "Redimensionando disco para ${DISK_SIZE}" \
    qm disk resize \
        "$VMID" \
        scsi0 \
        "$DISK_SIZE"

# ==============================================================================
# EFI / OVMF
# ==============================================================================

run_step \
    "Criando EFI Disk no ${STORAGE}" \
    qm set "$VMID" \
        --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"

# ==============================================================================
# TPM 2.0
# ==============================================================================

run_step \
    "Criando TPM 2.0 no ${STORAGE}" \
    qm set "$VMID" \
        --tpmstate0 "${STORAGE}:1,version=v2.0"

# ==============================================================================
# CLOUD-INIT DISK
# ==============================================================================

run_step \
    "Criando Cloud-Init Disk no ${STORAGE}" \
    qm set "$VMID" \
        --ide2 "${STORAGE}:cloudinit"

# ==============================================================================
# CLOUD-INIT ROOT
# ==============================================================================

run_step \
    "Configurando Cloud-Init para root" \
    qm set "$VMID" \
        --ciuser root \
        --cipassword "$ROOT_PASSWORD_HASH" \
        --ipconfig0 "ip=dhcp" \
        --ciupgrade 0

unset ROOT_PASSWORD_HASH

# ==============================================================================
# ATUALIZAR CLOUD-INIT
# ==============================================================================

run_step \
    "Atualizando Cloud-Init" \
    qm cloudinit update "$VMID"

# ==============================================================================
# VALIDAR CLOUD-INIT
# ==============================================================================

CURRENT_STEP="Validando Cloud-Init"

CLOUD_USER_DATA="$(
    qm cloudinit dump "$VMID" user 2>>"$LOG_FILE"
)"

echo "$CLOUD_USER_DATA" |
    grep -q '^user: root$' \
    || fail "Cloud-Init nao esta configurado para usuario root."

echo "$CLOUD_USER_DATA" |
    grep -q '^disable_root: False$' \
    || fail "Cloud-Init nao liberou o usuario root."

if echo "$CLOUD_USER_DATA" |
    grep -qE '^users:|^[[:space:]]*-[[:space:]]+default'
then
    fail "Cloud-Init ainda contem configuracao de usuario default."
fi

unset CLOUD_USER_DATA

msg_ok "Cloud-Init root validado"

# ==============================================================================
# VALIDAR HARDWARE FINAL
# ==============================================================================

CURRENT_STEP="Validando configuracao da VM"

VM_CONFIG="$(
    qm config "$VMID"
)"

echo "$VM_CONFIG" |
    grep -q '^bios: ovmf$' \
    || fail "BIOS OVMF nao configurada."

echo "$VM_CONFIG" |
    grep -q '^machine: q35' \
    || fail "Machine q35 nao configurada."

echo "$VM_CONFIG" |
    grep -q '^cpu: host' \
    || fail "CPU type host nao configurado."

echo "$VM_CONFIG" |
    grep -q '^scsihw: virtio-scsi-single$' \
    || fail "VirtIO SCSI Single nao configurado."

echo "$VM_CONFIG" |
    grep -qi "^net0: .*${MAC}" \
    || fail "MAC ${MAC} nao encontrada na VM."

echo "$VM_CONFIG" |
    grep -q '^agent: enabled=1' \
    || fail "QEMU Agent nao habilitado no Proxmox."

echo "$VM_CONFIG" |
    grep -q '^tpmstate0:' \
    || fail "TPM 2.0 nao configurado."

echo "$VM_CONFIG" |
    grep -q '^efidisk0:' \
    || fail "EFI Disk nao configurado."

echo "$VM_CONFIG" |
    grep -q '^ide2:.*cloudinit' \
    || fail "Cloud-Init Disk nao configurado."

unset VM_CONFIG

msg_ok "Hardware da VM validado"

# ==============================================================================
# HA
#
# state=started entrega o gerenciamento da inicializacao ao HA.
# Nao executar "qm start" separadamente.
#
# ==============================================================================

run_step \
    "Adicionando VM ao HA" \
    ha-manager add \
        "vm:${VMID}" \
        --state started

# ==============================================================================
# VALIDAR HA
# ==============================================================================

CURRENT_STEP="Validando recurso HA"

if ! ha-manager config |
    grep -qE "(^|[[:space:]])vm:${VMID}([[:space:]]|$)"
then
    fail "VM criada, mas o recurso HA vm:${VMID} nao foi encontrado."
fi

msg_ok "Recurso HA vm:${VMID} configurado"

# ==============================================================================
# RESULTADO FINAL
# ==============================================================================

echo
echo -e "${GN}============================================================${CL}"
echo -e "${GN} PROVISIONAMENTO CONCLUIDO${CL}"
echo -e "${GN}============================================================${CL}"
echo

printf '  %-23s %s\n' "VMID:"              "$VMID"
printf '  %-23s %s\n' "Nome:"              "$NAME"

echo

printf '  %-23s %s\n' "CPU:"               "${CORES} vCPU"
printf '  %-23s %s\n' "CPU Type:"          "host"
printf '  %-23s %s\n' "RAM:"               "${MEMORY} MiB"
printf '  %-23s %s\n' "Ballooning:"         "desabilitado"

echo

printf '  %-23s %s\n' "Disco:"             "$DISK_SIZE"
printf '  %-23s %s\n' "Storage:"           "$STORAGE"
printf '  %-23s %s\n' "Controller:"        "VirtIO SCSI Single"
printf '  %-23s %s\n' "Discard:"           "ON"
printf '  %-23s %s\n' "IOThread:"          "ON"

echo

printf '  %-23s %s\n' "Rede:"              "VirtIO"
printf '  %-23s %s\n' "Bridge:"            "$BRIDGE"
printf '  %-23s %s\n' "MAC:"               "$MAC"
printf '  %-23s %s\n' "IPv4:"              "DHCP"

echo

printf '  %-23s %s\n' "Machine:"           "q35"
printf '  %-23s %s\n' "BIOS:"              "OVMF / UEFI"
printf '  %-23s %s\n' "EFI Storage:"       "$STORAGE"
printf '  %-23s %s\n' "TPM:"               "${STORAGE} / TPM 2.0"

echo

printf '  %-23s %s\n' "Cloud-Init:"        "$STORAGE"
printf '  %-23s %s\n' "Usuario:"           "root"
printf '  %-23s %s\n' "Senha root:"        "configurada"
printf '  %-23s %s\n' "Usuario debian:"    "removido"
printf '  %-23s %s\n' "SSH root:"          "habilitado"
printf '  %-23s %s\n' "SSH por senha:"     "habilitado"

echo

printf '  %-23s %s\n' "QEMU Agent:"        "instalado/habilitado"
printf '  %-23s %s\n' "HA Resource:"       "vm:${VMID}"
printf '  %-23s %s\n' "HA Requested State:" "started"

echo

printf '  %-23s %s\n' "Log completo:"       "$LOG_FILE"

# ==============================================================================
# CONFIGURACAO EFETIVA
# ==============================================================================

echo
echo -e "${BL}============================================================${CL}"
echo -e "${BL} CONFIGURACAO EFETIVA DA VM${CL}"
echo -e "${BL}============================================================${CL}"
echo

qm config "$VMID" |
    grep -E \
        '^(agent|bios|boot|ciuser|cores|cpu|efidisk0|ide2|ipconfig0|machine|memory|name|net0|scsi0|scsihw|serial0|tpmstate0|vga):'

# ==============================================================================
# HA STATUS
# ==============================================================================

echo
echo -e "${BL}============================================================${CL}"
echo -e "${BL} ESTADO HA${CL}"
echo -e "${BL}============================================================${CL}"
echo

ha-manager status |
    grep -E "(^quorum|^master|vm:${VMID})" \
    || true

# ==============================================================================
# ACESSO
# ==============================================================================

echo
echo -e "${BL}============================================================${CL}"
echo -e "${BL} ACESSO AO DEBIAN${CL}"
echo -e "${BL}============================================================${CL}"
echo

echo -e " Usuario:"
echo
echo -e "   ${GN}root${CL}"
echo

echo -e " Apos obter o IP recebido via DHCP:"
echo
echo -e "   ${BL}ssh root@IP_DA_VM${CL}"
echo

echo -e "${GN}Provisionamento finalizado com sucesso.${CL}"
echo

cat >>"$LOG_FILE" <<EOF

============================================================
Provisionamento concluido
Fim: $(date '+%Y-%m-%d %H:%M:%S')
============================================================
EOF
