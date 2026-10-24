#!/usr/bin/env bash

# =============================================================================
#  PROVISIONAMENTO VM DEBIAN 13 - PROXMOX VE / CEPH / HA
#
#  VMID.........: 900
#  NAME.........: srvAD01
#  STORAGE......: Tank (Ceph/RBD)
#  IMAGE........: Debian 13 Trixie GenericCloud
#  IMAGE LOCAL..: local:/var/lib/vz/template/iso/
#
#  CPU..........: 4 vCPU / host
#  RAM..........: 4096 MiB
#  DISK.........: 32 GB
#  SCSI.........: VirtIO SCSI Single
#  DISCARD......: sim
#  IOTHREAD.....: sim
#
#  NETWORK......: VirtIO
#  BRIDGE.......: vmbr0
#  MAC..........: BC:24:11:66:25:E3
#  IPv4.........: DHCP
#
#  MACHINE......: q35
#  BIOS.........: OVMF / UEFI
#  EFI..........: Tank
#  TPM..........: Tank / TPM 2.0
#
#  CLOUD-INIT...: sim
#  USUARIO......: root
#  ROOT SSH.....: senha habilitada
#  QEMU AGENT...: instalado e habilitado
#  HA...........: sim
#
#  USUARIO "debian":
#    removido da imagem antes da importacao.
#
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit nullglob

# =============================================================================
# CONFIGURACAO
# =============================================================================

VMID="900"
NAME="srvAD01"

STORAGE="Tank"
LOCAL_STORAGE="local"

BRIDGE="vmbr0"
MAC="BC:24:11:66:25:E3"

CORES="4"
MEMORY="4096"
DISK_SIZE="32G"

IMAGE_NAME="debian-13-genericcloud-amd64.qcow2"

IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/${IMAGE_NAME}"
CHECKSUM_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"

LOCAL_BASE="/var/lib/vz"
IMAGE_DIR="${LOCAL_BASE}/template/iso"

# Imagem oficial fica preservada aqui.
IMAGE_PATH="${IMAGE_DIR}/${IMAGE_NAME}"

# Copia temporaria que sera personalizada.
WORK_IMAGE="${IMAGE_DIR}/.${VMID}-${NAME}-custom.qcow2"

# Arquivo temporario usado para configurar SSH dentro da imagem.
SSH_CONFIG_HOST="/tmp/${VMID}-${NAME}-root-ssh.conf"

CURRENT_STEP="Inicializacao"

# =============================================================================
# CORES
# =============================================================================

RD='\033[01;31m'
YW='\033[33m'
GN='\033[1;92m'
BL='\033[1;94m'
CY='\033[1;96m'
CL='\033[m'

BFR='\r\033[K'

CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"
ARROW="${CY}➜${CL}"

# =============================================================================
# FUNCOES
# =============================================================================

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

  echo -e "${BFR} ${CM} ${GN}$1${CL}"

}

msg_warn() {

  echo -e "${BFR} ${INFO} ${YW}$1${CL}"

}

msg_error() {

  echo -e "${BFR} ${CROSS} ${RD}$1${CL}" >&2

}

fail() {

  msg_error "$1"
  exit 1

}

cleanup() {

  unset ROOT_PASSWORD ROOT_PASSWORD_CONFIRM 2>/dev/null || true

  rm -f "$WORK_IMAGE" 2>/dev/null || true
  rm -f "$SSH_CONFIG_HOST" 2>/dev/null || true

}

on_error() {

  local EXIT_CODE=$?
  local LINE="${1:-?}"

  echo
  msg_error "Falha durante: ${CURRENT_STEP}"

  echo
  echo -e " ${RD}ETAPA........:${CL} ${CURRENT_STEP}"
  echo -e " ${RD}CODIGO.......:${CL} ${EXIT_CODE}"
  echo -e " ${RD}LINHA........:${CL} ${LINE}"

  if qm status "$VMID" &>/dev/null; then

    echo
    msg_warn "A VM ${VMID} foi criada parcialmente e NAO sera removida automaticamente."

    echo
    echo -e " Verifique:"
    echo
    echo -e "   ${BL}qm config ${VMID}${CL}"
    echo -e "   ${BL}pvesm list ${STORAGE} --vmid ${VMID}${CL}"
    echo

  fi

  exit "$EXIT_CODE"

}

trap cleanup EXIT
trap 'on_error $LINENO' ERR

# =============================================================================
# CABECALHO
# =============================================================================

header_info

echo -e "${CY}Configuracao:${CL}"
echo

printf '  %-20s %s\n' "VMID:"          "$VMID"
printf '  %-20s %s\n' "Nome:"          "$NAME"
printf '  %-20s %s\n' "CPU:"           "${CORES} vCPU / host"
printf '  %-20s %s\n' "RAM:"           "${MEMORY} MiB"
printf '  %-20s %s\n' "Disco:"         "${DISK_SIZE}"
printf '  %-20s %s\n' "Storage:"       "$STORAGE"
printf '  %-20s %s\n' "SCSI:"          "VirtIO SCSI Single"
printf '  %-20s %s\n' "Discard:"       "sim"
printf '  %-20s %s\n' "IOThread:"      "sim"
printf '  %-20s %s\n' "Bridge:"        "$BRIDGE"
printf '  %-20s %s\n' "MAC:"           "$MAC"
printf '  %-20s %s\n' "IPv4:"          "DHCP"
printf '  %-20s %s\n' "Machine:"       "q35"
printf '  %-20s %s\n' "BIOS:"          "OVMF / UEFI"
printf '  %-20s %s\n' "EFI:"           "$STORAGE"
printf '  %-20s %s\n' "TPM:"           "${STORAGE} / TPM 2.0"
printf '  %-20s %s\n' "Usuario:"       "root"
printf '  %-20s %s\n' "SSH root:"      "senha"
printf '  %-20s %s\n' "QEMU Agent:"    "sim"
printf '  %-20s %s\n' "HA:"            "sim"

echo

# =============================================================================
# ROOT
# =============================================================================

CURRENT_STEP="Validando execucao como root"

[[ "$EUID" -eq 0 ]] \
  || fail "Execute este script como root no host Proxmox."

msg_ok "$CURRENT_STEP"

# =============================================================================
# SOLICITAR SENHA ROOT
# =============================================================================

CURRENT_STEP="Definindo senha do usuario root"

echo
echo -e "${CY}Senha do ROOT da nova VM:${CL}"
echo

while true
do

  read -rsp " Digite a senha do root: " ROOT_PASSWORD
  echo

  [[ -n "$ROOT_PASSWORD" ]] || {
    msg_warn "A senha nao pode ficar vazia."
    continue
  }

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

echo

# =============================================================================
# COMANDOS BASICOS
# =============================================================================

CURRENT_STEP="Validando ferramentas do Proxmox"

for CMD in \
  qm \
  pvesm \
  pvecm \
  ha-manager \
  qemu-img \
  wget \
  sha512sum \
  ip \
  awk \
  grep
do

  command -v "$CMD" >/dev/null 2>&1 \
    || fail "Comando obrigatorio nao encontrado: ${CMD}"

done

msg_ok "$CURRENT_STEP"

# =============================================================================
# LIBGUESTFS
# =============================================================================

CURRENT_STEP="Validando virt-customize"

if ! command -v virt-customize >/dev/null 2>&1; then

  msg_info "Instalando libguestfs-tools"

  apt-get update -qq

  DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq libguestfs-tools >/dev/null

  msg_ok "libguestfs-tools instalado"

else

  msg_ok "virt-customize disponivel"

fi

# =============================================================================
# STORAGE LOCAL
# =============================================================================

CURRENT_STEP="Validando storage ${LOCAL_STORAGE}"

pvesm status --storage "$LOCAL_STORAGE" 2>/dev/null |
  awk -v S="$LOCAL_STORAGE" '
    $1 == S && $2 == "dir" && $3 == "active" {
      OK=1
    }

    END {
      exit !OK
    }
  ' || fail "Storage '${LOCAL_STORAGE}' nao esta ativo ou nao e DIR."

msg_ok "$CURRENT_STEP"

# =============================================================================
# STORAGE CEPH
# =============================================================================

CURRENT_STEP="Validando storage ${STORAGE}"

pvesm status --storage "$STORAGE" 2>/dev/null |
  awk -v S="$STORAGE" '
    $1 == S && $2 == "rbd" && $3 == "active" {
      OK=1
    }

    END {
      exit !OK
    }
  ' || fail "Storage '${STORAGE}' nao esta ativo ou nao e RBD."

msg_ok "$CURRENT_STEP"

# =============================================================================
# BRIDGE
# =============================================================================

CURRENT_STEP="Validando bridge ${BRIDGE}"

ip link show "$BRIDGE" >/dev/null 2>&1 \
  || fail "Bridge ${BRIDGE} nao encontrada."

msg_ok "$CURRENT_STEP"

# =============================================================================
# VMID
# =============================================================================

CURRENT_STEP="Validando VMID ${VMID}"

if qm status "$VMID" &>/dev/null; then

  fail "VMID ${VMID} ja existe."

fi

msg_ok "$CURRENT_STEP"

# =============================================================================
# MAC
# =============================================================================

CURRENT_STEP="Validando endereco MAC"

if grep -Rqi \
  -- "$MAC" \
  /etc/pve/qemu-server/*.conf \
  2>/dev/null
then

  fail "MAC ${MAC} ja esta configurado em outra VM."

fi

msg_ok "$CURRENT_STEP"

# =============================================================================
# QUORUM
# =============================================================================

CURRENT_STEP="Validando quorum"

pvecm status 2>/dev/null |
  grep -Eq '^Quorate:[[:space:]]+Yes$' \
  || fail "Cluster Proxmox esta sem quorum."

msg_ok "$CURRENT_STEP"

# =============================================================================
# HA
# =============================================================================

CURRENT_STEP="Validando HA Manager"

ha-manager status >/dev/null 2>&1 \
  || fail "HA Manager nao esta disponivel."

msg_ok "$CURRENT_STEP"

# =============================================================================
# DIRETORIO LOCAL
# =============================================================================

CURRENT_STEP="Preparando diretorio da imagem"

mkdir -p "$IMAGE_DIR"

msg_ok "$CURRENT_STEP"

# =============================================================================
# OBTER CHECKSUM OFICIAL
# =============================================================================

CURRENT_STEP="Obtendo SHA512 oficial"

msg_info "$CURRENT_STEP"

EXPECTED_SHA="$(
  wget -qO- "$CHECKSUM_URL" |
    awk -v F="$IMAGE_NAME" '
      $2 == F || $2 == "*" F {
        print $1
        exit
      }
    '
)"

[[ -n "$EXPECTED_SHA" ]] \
  || fail "Nao foi possivel obter SHA512 oficial."

msg_ok "$CURRENT_STEP"

# =============================================================================
# VALIDAR / BAIXAR IMAGEM
# =============================================================================

DOWNLOAD_IMAGE="yes"

if [[ -s "$IMAGE_PATH" ]]; then

  CURRENT_STEP="Validando imagem existente"

  msg_info "$CURRENT_STEP"

  ACTUAL_SHA="$(
    sha512sum "$IMAGE_PATH" |
      awk '{print $1}'
  )"

  if [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]]; then

    DOWNLOAD_IMAGE="no"

    msg_ok "Imagem oficial atual ja existe"

  else

    msg_warn "Imagem existente nao corresponde ao latest atual"

  fi

fi

if [[ "$DOWNLOAD_IMAGE" == "yes" ]]; then

  CURRENT_STEP="Baixando Debian 13 GenericCloud"

  msg_info "$CURRENT_STEP"

  rm -f "${IMAGE_PATH}.part"

  wget \
    --progress=bar:force:noscroll \
    -O "${IMAGE_PATH}.part" \
    "$IMAGE_URL"

  mv "${IMAGE_PATH}.part" "$IMAGE_PATH"

  msg_ok "$CURRENT_STEP"

fi

# =============================================================================
# SHA512
# =============================================================================

CURRENT_STEP="Validando SHA512"

msg_info "$CURRENT_STEP"

ACTUAL_SHA="$(
  sha512sum "$IMAGE_PATH" |
    awk '{print $1}'
)"

[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] \
  || fail "SHA512 da imagem nao corresponde ao SHA512 oficial."

msg_ok "SHA512 valido"

# =============================================================================
# QCOW2
# =============================================================================

CURRENT_STEP="Validando QCOW2"

qemu-img check "$IMAGE_PATH" >/dev/null

msg_ok "$CURRENT_STEP"

# =============================================================================
# CRIAR COPIA DE TRABALHO
# =============================================================================

CURRENT_STEP="Criando copia temporaria da imagem"

msg_info "$CURRENT_STEP"

rm -f "$WORK_IMAGE"

cp \
  --reflink=auto \
  --sparse=always \
  "$IMAGE_PATH" \
  "$WORK_IMAGE"

msg_ok "$CURRENT_STEP"

# =============================================================================
# CONFIGURACAO SSH
# =============================================================================
#
# O prefixo 00 e proposital.
#
# O OpenSSH usa o primeiro valor encontrado para varias diretivas.
# Como /etc/ssh/sshd_config.d/*.conf e processado em ordem,
# este arquivo deve aparecer antes de eventuais arquivos cloud-image.
#
# =============================================================================

CURRENT_STEP="Preparando configuracao SSH root"

cat > "$SSH_CONFIG_HOST" <<'EOF'
# Gerenciado pelo provisionamento Proxmox

PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF

chmod 600 "$SSH_CONFIG_HOST"

msg_ok "$CURRENT_STEP"

# =============================================================================
# PERSONALIZAR IMAGEM
# =============================================================================

CURRENT_STEP="Personalizando Debian 13"

msg_info "$CURRENT_STEP"

virt-customize \
  -a "$WORK_IMAGE" \
  --install openssh-server,qemu-guest-agent \
  --mkdir /etc/ssh/sshd_config.d \
  --upload "${SSH_CONFIG_HOST}:/etc/ssh/sshd_config.d/00-root-password-login.conf" \
  --chmod '0644:/etc/ssh/sshd_config.d/00-root-password-login.conf' \
  --run-command 'if id debian >/dev/null 2>&1; then userdel -r debian || true; fi' \
  --run-command 'systemctl enable ssh.service >/dev/null 2>&1 || true' \
  --run-command 'systemctl enable qemu-guest-agent.service >/dev/null 2>&1 || true' \
  --run-command '/usr/sbin/sshd -t'

msg_ok "$CURRENT_STEP"

# =============================================================================
# VALIDAR IMAGEM CUSTOMIZADA
# =============================================================================

CURRENT_STEP="Validando imagem personalizada"

qemu-img check "$WORK_IMAGE" >/dev/null

msg_ok "$CURRENT_STEP"

# =============================================================================
# CRIAR VM
# =============================================================================

CURRENT_STEP="Criando VM ${VMID}"

msg_info "$CURRENT_STEP"

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
  --description "Debian 13 Trixie | srvAD01 | Ceph RBD | HA"

msg_ok "$CURRENT_STEP"

# =============================================================================
# IMPORTAR DISCO
# =============================================================================

CURRENT_STEP="Importando disco para ${STORAGE}"

msg_info "$CURRENT_STEP"

qm disk import \
  "$VMID" \
  "$WORK_IMAGE" \
  "$STORAGE" \
  --format raw \
  >/dev/null

msg_ok "$CURRENT_STEP"

# =============================================================================
# IDENTIFICAR DISCO
# =============================================================================

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

msg_ok "${CURRENT_STEP}: ${IMPORTED_DISK}"

# =============================================================================
# SCSI0
# =============================================================================

CURRENT_STEP="Configurando disco SCSI"

qm set "$VMID" \
  --scsi0 "${IMPORTED_DISK},discard=on,iothread=1" \
  >/dev/null

qm set "$VMID" \
  --boot order=scsi0 \
  >/dev/null

msg_ok "$CURRENT_STEP"

# =============================================================================
# RESIZE
# =============================================================================

CURRENT_STEP="Redimensionando disco para ${DISK_SIZE}"

qm disk resize \
  "$VMID" \
  scsi0 \
  "$DISK_SIZE" \
  >/dev/null

msg_ok "$CURRENT_STEP"

# =============================================================================
# EFI
# =============================================================================

CURRENT_STEP="Criando EFI Disk"

qm set "$VMID" \
  --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0" \
  >/dev/null

msg_ok "$CURRENT_STEP"

# =============================================================================
# TPM
# =============================================================================

CURRENT_STEP="Criando TPM 2.0"

qm set "$VMID" \
  --tpmstate0 "${STORAGE}:1,version=v2.0" \
  >/dev/null

msg_ok "$CURRENT_STEP"

# =============================================================================
# CLOUD-INIT
# =============================================================================

CURRENT_STEP="Criando Cloud-Init Disk"

qm set "$VMID" \
  --ide2 "${STORAGE}:cloudinit" \
  >/dev/null

msg_ok "$CURRENT_STEP"

# =============================================================================
# CLOUD-INIT ROOT
# =============================================================================

CURRENT_STEP="Configurando usuario root"

msg_info "$CURRENT_STEP"

qm set "$VMID" \
  --ciuser root \
  --cipassword "$ROOT_PASSWORD" \
  --ipconfig0 ip=dhcp \
  --ciupgrade 0 \
  >/dev/null

qm cloudinit update "$VMID" >/dev/null

msg_ok "$CURRENT_STEP"

# A senha nao precisa mais permanecer na variavel.
unset ROOT_PASSWORD

# =============================================================================
# VALIDAR CLOUD-INIT
# =============================================================================

CURRENT_STEP="Validando Cloud-Init root"

CLOUDINIT_DATA="$(
  qm cloudinit dump "$VMID" user
)"

echo "$CLOUDINIT_DATA" |
  grep -q '^user: root$' \
  || fail "Cloud-Init nao esta configurado para root."

echo "$CLOUDINIT_DATA" |
  grep -q '^disable_root: False$' \
  || fail "Cloud-Init nao liberou root."

msg_ok "$CURRENT_STEP"

# =============================================================================
# HA
# =============================================================================

CURRENT_STEP="Adicionando VM ao HA"

msg_info "$CURRENT_STEP"

ha-manager add \
  "vm:${VMID}" \
  --state started \
  >/dev/null

msg_ok "$CURRENT_STEP"

# =============================================================================
# VALIDAR HA
# =============================================================================

CURRENT_STEP="Validando recurso HA"

ha-manager config |
  grep -q "vm:${VMID}" \
  || fail "VM criada, mas nao registrada corretamente no HA."

msg_ok "$CURRENT_STEP"

# =============================================================================
# RESULTADO
# =============================================================================

echo
echo -e "${GN}============================================================${CL}"
echo -e "${GN} VM CRIADA COM SUCESSO${CL}"
echo -e "${GN}============================================================${CL}"
echo

printf '  %-22s %s\n' "VMID:"             "$VMID"
printf '  %-22s %s\n' "Nome:"             "$NAME"
printf '  %-22s %s\n' "CPU:"              "${CORES} vCPU / host"
printf '  %-22s %s\n' "RAM:"              "${MEMORY} MiB"
printf '  %-22s %s\n' "Disco:"            "${DISK_SIZE}"
printf '  %-22s %s\n' "Storage:"          "$STORAGE"
printf '  %-22s %s\n' "SCSI:"             "VirtIO SCSI Single"
printf '  %-22s %s\n' "Discard:"          "ON"
printf '  %-22s %s\n' "IOThread:"         "ON"

echo

printf '  %-22s %s\n' "Rede:"             "VirtIO"
printf '  %-22s %s\n' "Bridge:"           "$BRIDGE"
printf '  %-22s %s\n' "MAC:"              "$MAC"
printf '  %-22s %s\n' "IPv4:"             "DHCP"

echo

printf '  %-22s %s\n' "Machine:"          "q35"
printf '  %-22s %s\n' "BIOS:"             "OVMF / UEFI"
printf '  %-22s %s\n' "EFI:"              "$STORAGE"
printf '  %-22s %s\n' "TPM:"              "${STORAGE} / TPM 2.0"

echo

printf '  %-22s %s\n' "Usuario:"          "root"
printf '  %-22s %s\n' "Usuario debian:"   "removido"
printf '  %-22s %s\n' "SSH root:"         "habilitado"
printf '  %-22s %s\n' "SSH por senha:"    "habilitado"
printf '  %-22s %s\n' "QEMU Agent:"       "instalado/habilitado"
printf '  %-22s %s\n' "HA:"               "vm:${VMID}"
printf '  %-22s %s\n' "HA State:"         "started"

echo

# =============================================================================
# CONFIGURACAO EFETIVA
# =============================================================================

echo -e "${BL}============================================================${CL}"
echo -e "${BL} CONFIGURACAO EFETIVA DA VM${CL}"
echo -e "${BL}============================================================${CL}"
echo

qm config "$VMID" |
  grep -E \
  '^(agent|bios|boot|ciuser|cores|cpu|efidisk0|ide2|ipconfig0|machine|memory|name|net0|scsi0|scsihw|serial0|tpmstate0|vga):'

echo

# =============================================================================
# HA
# =============================================================================

echo -e "${BL}============================================================${CL}"
echo -e "${BL} ESTADO HA${CL}"
echo -e "${BL}============================================================${CL}"
echo

ha-manager status |
  grep -E "(^quorum|^master|vm:${VMID})" \
  || true

echo

# =============================================================================
# ACESSO
# =============================================================================

echo -e "${BL}============================================================${CL}"
echo -e "${BL} ACESSO${CL}"
echo -e "${BL}============================================================${CL}"
echo

echo -e " Usuario SSH:"
echo
echo -e "   ${GN}root${CL}"
echo
echo -e " Depois de descobrir o IP recebido via DHCP:"
echo
echo -e "   ${BL}ssh root@IP_DA_VM${CL}"
echo

echo -e "${GN}Provisionamento concluido.${CL}"
echo
