#!/usr/bin/env bash

set -Eeuo pipefail
set +H

# ============================================================
# VARIÁVEIS OBRIGATÓRIAS
# ============================================================

: "${VMID:?Informe VMID}"
: "${HOSTNAME:?Informe HOSTNAME}"
: "${IP:?Informe IP}"
: "${MAC:?Informe MAC}"

: "${DOMAIN:?Informe DOMAIN}"
: "${GW:?Informe GW}"

: "${DNS1:?Informe DNS1}"
: "${DNS2:?Informe DNS2}"

: "${NTP:?Informe NTP}"

: "${STORAGE:?Informe STORAGE}"
: "${BRIDGE:?Informe BRIDGE}"

# ============================================================
# VARIÁVEIS OPCIONAIS
# ============================================================

PREFIX="${PREFIX:-24}"

CPU="${CPU:-4}"
RAM="${RAM:-4096}"
DISK="${DISK:-32G}"

OS_VERSION="${OS_VERSION:-13}"
MACHINE="${MACHINE:-q35}"

TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
IFACE="${IFACE:-eth0}"

RECREATE="${RECREATE:-yes}"

# Aumentado para 10 minutos (600 s) – Cloud‑Init pode levar mais tempo em imagens Debian
CLOUDINIT_WAIT_SECONDS="${CLOUDINIT_WAIT_SECONDS:-600}"
AGENT_WAIT_SECONDS="${AGENT_WAIT_SECONDS:-240}"
NTP_WAIT_SECONDS="${NTP_WAIT_SECONDS:-60}"

# URL segura para o script da comunidade (sem caracteres que causem erro de porta)
COMMUNITY_SCRIPT_URL="${COMMUNITY_SCRIPT_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/vm/debian-vm.sh}"

# Opcional: ROOT_PASSWORD pode ser fornecida pelo ambiente.
ROOT_PASSWORD="${ROOT_PASSWORD:-}"

# ============================================================
# DERIVAÇÕES
# ============================================================

FQDN="${HOSTNAME}.${DOMAIN}"
CIDR="${IP}/${PREFIX}"

LOG="/tmp/create-${HOSTNAME}.log"
CRED_FILE="/tmp/${HOSTNAME}-${VMID}-cloud-init-credentials.txt"

ETAPA="INICIO"
ROOTPASS=""

# ============================================================
# LOG
# ============================================================

exec 3>&1 4>&2
: >"$LOG"
exec >"$LOG" 2>&1

# ============================================================
# ERRO
# ============================================================

falha() {
    RC=$?
    trap - ERR
    rm -f "$CRED_FILE" 2>/dev/null || true
    ROOTPASS=""
    ROOT_PASSWORD=""
    exec 1>&3 2>&4
    clear 2>/dev/null || true
    echo "============================================================"
    echo " ${HOSTNAME} - ERRO"
    echo "============================================================"
    echo
    echo "ETAPA....... $ETAPA"
    echo "CODIGO...... $RC"
    echo "LOG......... $LOG"
    echo
    echo "ULTIMAS LINHAS:"
    echo
    tail -n 20 "$LOG" 2>/dev/null || true
    echo
    echo "============================================================"
    exit "$RC"
}

trap falha ERR

# ============================================================
# PRÉ‑VALIDAÇÃO DO PROXMOX
# ============================================================

ETAPA="VALIDAR_PROXMOX"
[[ "$(id -u)" == "0" ]]
command -v qm >/dev/null
command -v pvesm >/dev/null
command -v python3 >/dev/null
command -v curl >/dev/null
pvesm status -storage "$STORAGE" >/dev/null
ip link show "$BRIDGE" >/dev/null

# ============================================================
# VALIDAR PARÂMETROS
# ============================================================

ETAPA="VALIDAR_PARAMETROS"
python3 - "$IP" "$PREFIX" "$GW" "$DNS1" "$DNS2" "$NTP" <<'PY'
import ipaddress, sys
ip, prefix = sys.argv[1], sys.argv[2]
ipaddress.ip_interface(f"{ip}/{prefix}")
for v in sys.argv[3:]:
    ipaddress.ip_address(v)
PY

if [[ ! "$MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
    echo "MAC inválido: ${MAC}"; false; fi
if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo "VMID inválido: ${VMID}"; false; fi

# ============================================================
# SENHA ROOT
# ============================================================

ETAPA="SENHA_ROOT"
if [[ -n "$ROOT_PASSWORD" ]]; then
    ROOTPASS="$ROOT_PASSWORD"
    echo ">>> Etapa: CRIAR_VM – senha root fornecida via ROOT_PASSWORD, iniciando criação da VM ${HOSTNAME} (VMID $VMID)" | tee -a "$LOG"
else
    if [ -t 0 ]; then
        exec 1>&3 2>&4
        clear 2>/dev/null || true
        echo "============================================================"
        echo " CRIAR ${HOSTNAME}"
        echo "============================================================"
        echo
        echo "VMID........ $VMID"
        echo "HOSTNAME.... $HOSTNAME"
        echo "FQDN........ $FQDN"
        echo "IP.......... $CIDR"
        echo "MAC......... $MAC"
        echo "STORAGE..... $STORAGE"
        echo "BRIDGE...... $BRIDGE"
        echo "CONSOLE..... noVNC"
        echo
        while true; do
            printf "Nova senha root: " > /dev/tty
            IFS= read -r -s ROOTPASS < /dev/tty
            printf "\n" > /dev/tty
            printf "Repita a senha:  " > /dev/tty
            IFS= read -r -s ROOTPASS2 < /dev/tty
            printf "\n" > /dev/tty
            [[ -z "$ROOTPASS" ]] && echo "Senha vazia." > /dev/tty && continue
            [[ "$ROOTPASS" != "$ROOTPASS2" ]] && echo "Senhas diferentes." > /dev/tty && continue
            unset ROOTPASS2
            break
        done
        echo ">>> Etapa: CRIAR_VM – senha root configurada, iniciando criação da VM ${HOSTNAME} (VMID $VMID)" | tee -a "$LOG"
        exec >>"$LOG" 2>&1
    else
        echo "Erro: ROOT_PASSWORD não definido e nenhum TTY disponível para solicitar a senha." >&2
        exit 1
    fi
fi

msg=">>> Etapa: CRIAR_VM - Iniciando criação da VM ${HOSTNAME} (VMID $VMID)"
echo "$msg" | tee -a "$LOG"
printf "%s\n" "$msg" > /dev/tty

# ============================================================
# VM JÁ EXISTENTE
# ============================================================

ETAPA="VERIFICAR_VM_EXISTENTE"
if qm status "$VMID" >/dev/null 2>&1; then
    if [[ "$RECREATE" != "yes" ]]; then
        echo "VMID $VMID já existe e RECREATE não está habilitado."; false; fi
    qm stop "$VMID" >/dev/null 2>&1 || true
    sleep 2
    qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1
fi
if qm status "$VMID" >/dev/null 2>&1; then
    echo "VMID $VMID ainda existe."; false; fi
rm -f "$CRED_FILE" 2>/dev/null || true

# ============================================================
# CRIAR VM
# ============================================================

ETAPA="CRIAR_VM"
# Baixar script da comunidade de forma segura
script_content=$(curl -fsSL "$COMMUNITY_SCRIPT_URL") || { echo "Erro ao baixar script da comunidade: $COMMUNITY_SCRIPT_URL" >&2; exit 1; }
# Executar script que cria a VM (ele gera o arquivo de configuração)
env VM_UNATTENDED=1 \
    VM_OS_VERSION="$OS_VERSION" \
    VM_VMID="$VMID" \
    VM_DISK_SIZE="$DISK" \
    VM_HOSTNAME="$HOSTNAME" \
    VM_CORES="$CPU" \
    VM_RAM="$RAM" \
    VM_BRIDGE="$BRIDGE" \
    VM_MAC="$MAC" \
    VM_STORAGE="$STORAGE" \
    VM_MACHINE="$MACHINE" \
    VM_START="no" \
    VM_CLOUD_INIT="yes" \
    CLOUDINIT_USER="root" \
    CLOUDINIT_PASSWORD="$ROOTPASS" \
    CLOUDINIT_NETWORK_MODE="dhcp" \
    CLOUDINIT_DNS="$DNS1 $DNS2" \
    CLOUDINIT_SEARCH_DOMAIN="$DOMAIN" \
    bash -c "$script_content"

# Aguarda o arquivo de configuração da VM existir (máx 30 s)
wait_secs=0
while [[ ! -f "/etc/pve/qemu-server/${VMID}.conf" && $wait_secs -lt 30 ]]; do
    sleep 1
    ((wait_secs++))
done
[[ -f "/etc/pve/qemu-server/${VMID}.conf" ]] || { echo "Arquivo de configuração da VM $VMID não foi criado após criação." >&2; exit 2; }

# ============================================================
# CONFIGURAR PROXMOX
# ============================================================

ETAPA="CONFIGURAR_PROXMOX"
qm set "$VMID" --vga std >/dev/null
qm set "$VMID" --tablet 1 >/dev/null
qm set "$VMID" --agent enabled=1 >/dev/null
qm set "$VMID" --onboot 1 >/dev/null
qm set "$VMID" --boot order=scsi0 >/dev/null
qm set "$VMID" --delete serial0 >/dev/null 2>&1 || true

# ============================================================
# PRIMEIRO BOOT
# ============================================================

ETAPA="PRIMEIRO_BOOT"
qm start "$VMID"

# ============================================================
# AGUARDAR QEMU GUEST AGENT
# ============================================================

ETAPA="AGUARDAR_AGENT"
AGENT_OK=0
AGENT_WAITED=0
while (( AGENT_WAITED < AGENT_WAIT_SECONDS )); do
    if qm guest cmd "$VMID" ping >/dev/null 2>&1; then
        AGENT_OK=1
        break
    fi
    sleep 2
    AGENT_WAITED=$((AGENT_WAITED + 2))
done
[[ "$AGENT_OK" == "1" ]] || { echo "QEMU Guest Agent não respondeu."; false; }

# ============================================================
# AGUARDAR CLOUD‑INIT (tempo aumentado)
# ============================================================

ETAPA="AGUARDAR_CLOUD_INIT"
CI_OK=0
CI_WAITED=0
while (( CI_WAITED < CLOUDINIT_WAIT_SECONDS )); do
    CI_JSON=$(qm guest exec "$VMID" --timeout 20 -- bash -lc 'cloud-init status 2>/dev/null || true' 2>/dev/null || true)
    CI_STATUS=$(python3 - <<'PY' "$CI_JSON"
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('out-data','').strip())
except Exception:
    pass
PY
)
    if grep -qE 'status: (done|degraded)' <<<"$CI_STATUS"; then
        CI_OK=1
        break
    fi
    sleep 5   # aguarda um pouco mais entre tentativas
    CI_WAITED=$((CI_WAITED + 5))
done
[[ "$CI_OK" == "1" ]] || { echo "Cloud‑Init não terminou após $CLOUDINIT_WAIT_SECONDS s."; false; }

# ============================================================
# SCRIPT QUE SERÁ EXECUTADO DENTRO DA VM
# ============================================================

ETAPA="CONFIGURAR_GUEST"
GUEST_SCRIPT="$(cat <<'GUEST_EOF'
set -Eeuo pipefail
HOSTNAME_NEW="$1"
DOMAIN="$2"
IP="$3"
PREFIX="$4"
GW="$5"
DNS1="$6"
DNS2="$7"
NTP="$8"
MAC="$9"
TIMEZONE="${10}"
IFACE="${11}"
FQDN="${HOSTNAME_NEW}.${DOMAIN}"
CIDR="${IP}/${PREFIX}"
# Hostname
hostnamectl set-hostname "$HOSTNAME_NEW"
# /etc/hosts
cat > /etc/hosts <<EOF
127.0.0.1 localhost
${IP} ${FQDN} ${HOSTNAME_NEW}
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
# Netplan – rede estática
mkdir -p /etc/netplan
cat > /etc/netplan/01-ad-server.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      match:
        macaddress: ${MAC,,}
      set-name: ${IFACE}
      dhcp4: false
      dhcp6: false
      addresses:
        - ${CIDR}
      routes:
        - to: default
          via: ${GW}
      nameservers:
        addresses:
          - ${DNS1}
          - ${DNS2}
        search:
          - ${DOMAIN}
EOF
chmod 600 /etc/netplan/01-ad-server.yaml
netplan generate
# NTP – usando systemd‑timesyncd
mkdir -p /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/10-setec.conf <<EOF
[Time]
NTP=${NTP}
FallbackNTP=
EOF
timedatectl set-timezone "$TIMEZONE"
systemctl restart systemd-timesyncd
# SSH root password
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-root-password.conf <<'EOF2'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitEmptyPasswords no
UsePAM yes
EOF2
rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf 2>/dev/null || true
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null || true
passwd -u root >/dev/null 2>&1 || true
ssh-keygen -A
systemctl enable ssh && systemctl restart ssh
# QEMU Guest Agent
systemctl enable qemu-guest-agent >/dev/null 2>&1 || true
# noVNC / VGA – garante console tty0
mkdir -p /etc/default/grub.d
cat > /etc/default/grub.d/99-novnc.cfg <<'EOF3'
GRUB_TERMINAL_INPUT="console"
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0"
GRUB_CMDLINE_LINUX="console=tty0"
EOF3
update-grub >/dev/null
# Desabilita cloud‑init (já não será mais necessário)
 touch /etc/cloud/cloud-init.disabled
 sync
GUEST_EOF
)"
GUEST_B64=$(printf '%s' "$GUEST_SCRIPT" | base64 -w0)
GUEST_JSON=$(qm guest exec "$VMID" --timeout 180 -- bash -lc "printf '%s' '$GUEST_B64' | base64 -d | bash -s -- '$HOSTNAME' '$DOMAIN' '$IP' '$PREFIX' '$GW' '$DNS1' '$DNS2' '$NTP' '$MAC' '$TIMEZONE' '$IFACE'")
GUEST_RC=$(python3 - <<'PY' "$GUEST_JSON"
import json,sys; d=json.load(sys.stdin); print(d.get('exitcode',99))
PY
)
[[ "$GUEST_RC" == "0" ]] || { echo "Configuração interna retornou código $GUEST_RC."; false; }

# ============================================================
# LIMPAR SENHA E CREDENCIAL
# ============================================================

ETAPA="LIMPAR_CREDENCIAIS"
rm -f "$CRED_FILE"
ROOTPASS=""
ROOT_PASSWORD=""

# ============================================================
# REBOOT DEFINITIVO
# ============================================================

ETAPA="REBOOT_FINAL"
qm reboot "$VMID"
sleep 5

# ============================================================
# AGUARDAR GUEST AGENT NOVAMENTE
# ============================================================

ETAPA="AGUARDAR_AGENT_POS_REBOOT"
AGENT_OK=0
AGENT_WAITED=0
while (( AGENT_WAITED < AGENT_WAIT_SECONDS )); do
    if qm guest cmd "$VMID" ping >/dev/null 2>&1; then
        AGENT_OK=1
        break
    fi
    sleep 2
    AGENT_WAITED=$((AGENT_WAITED + 2))
done
[[ "$AGENT_OK" == "1" ]] || { echo "Guest Agent não retornou após reboot."; false; }

# ============================================================
# AGUARDAR NTP
# ============================================================

ETAPA="AGUARDAR_NTP"
NTP_OK=0
NTP_WAITED=0
while (( NTP_WAITED < NTP_WAIT_SECONDS )); do
    NTP_JSON=$(qm guest exec "$VMID" --timeout 15 -- bash -lc "timedatectl timesync-status 2>/dev/null | grep -q '$NTP'" 2>/dev/null || true)
    NTP_RC=$(python3 - <<'PY' "$NTP_JSON"
import json,sys; print(json.load(sys.stdin).get('exitcode',99))
PY
)
    [[ "$NTP_RC" == "0" ]] && { NTP_OK=1; break; }
    sleep 2
    NTP_WAITED=$((NTP_WAITED + 2))
done
[[ "$NTP_OK" == "1" ]] || { echo "NTP $NTP não foi confirmado."; false; }

# ============================================================
# VALIDACÃO INTERNA
# ============================================================

ETAPA="VALIDACAO_GUEST"
CHECK_SCRIPT="$(cat <<'CHECK_EOF'
set -Eeuo pipefail
EXPECTED_HOST="$1"
EXPECTED_FQDN="$2"
EXPECTED_IP="$3"
EXPECTED_PREFIX="$4"
EXPECTED_GW="$5"
EXPECTED_DNS1="$6"
EXPECTED_DNS2="$7"
EXPECTED_NTP="$8"
IFACE="$9"
HOST=$(hostname)
FQDN=$(hostname -f)
IP=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')
GW=$(ip route show default | awk '{print $3; exit}')
SSH=$(systemctl is-active ssh)
ROOTLOGIN=$(sshd -T | awk '$1=="permitrootlogin" {print $2; exit}')
PASSAUTH=$(sshd -T | awk '$1=="passwordauthentication" {print $2; exit}')
ROOTPW=$(passwd -S root | awk '{print $2}')
CLOUD="enabled"
[[ -f /etc/cloud/cloud-init.disabled ]] && CLOUD="disabled"
NTP_SERVER=$(timedatectl timesync-status 2>/dev/null | awk '/Server:/ {print $2; exit}')
DNS=$(resolvectl dns "$IFACE" 2>/dev/null | sed -E "s/^Link [0-9]+ \(${IFACE}\):[[:space:]]*//" | xargs)
GETTY=$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)
GATEWAY_TEST="FALHA"
ping -c1 -W2 "$EXPECTED_GW" >/dev/null 2>&1 && GATEWAY_TEST="OK"
DNS1_TEST="FALHA"
ping -c1 -W2 "$EXPECTED_DNS1" >/dev/null 2>&1 && DNS1_TEST="OK"
DNS2_TEST="FALHA"
ping -c1 -W2 "$EXPECTED_DNS2" >/dev/null 2>&1 && DNS2_TEST="OK"
INTERNET_TEST="FALHA"
getent ahostsv4 deb.debian.org >/dev/null 2>&1 && INTERNET_TEST="OK"
printf 'HOST=%s\n' "$HOST"
printf 'FQDN=%s\n' "$FQDN"
printf 'IP=%s\n' "$IP"
printf 'GW=%s\n' "$GW"
printf 'SSH=%s\n' "$SSH"
printf 'ROOTLOGIN=%s\n' "$ROOTLOGIN"
printf 'PASSAUTH=%s\n' "$PASSAUTH"
printf 'ROOTPW=%s\n' "$ROOTPW"
printf 'CLOUD=%s\n' "$CLOUD"
printf 'NTP=%s\n' "$NTP_SERVER"
printf 'DNS=%s\n' "$DNS"
printf 'GETTY=%s\n' "$GETTY"
printf 'GATEWAY_TEST=%s\n' "$GATEWAY_TEST"
printf 'DNS1_TEST=%s\n' "$DNS1_TEST"
printf 'DNS2_TEST=%s\n' "$DNS2_TEST"
printf 'INTERNET_TEST=%s\n' "$INTERNET_TEST"
CHECK_EOF
)"
CHECK_B64=$(printf '%s' "$CHECK_SCRIPT" | base64 -w0)
CHECK_JSON=$(qm guest exec "$VMID" --timeout 60 -- bash -lc "printf '%s' '$CHECK_B64' | base64 -d | bash -s -- '$HOSTNAME' '$FQDN' '$IP' '$PREFIX' '$GW' '$DNS1' '$DNS2' '$NTP' '$IFACE'")
CHECK_RC=$(python3 - <<'PY' "$CHECK_JSON"
import json,sys; print(json.load(sys.stdin).get('exitcode',99))
PY
)
[[ "$CHECK_RC" == "0" ]]
CHECK_OUT=$(python3 - <<'PY' "$CHECK_JSON"
import json,sys; print(json.load(sys.stdin).get('out-data',''), end='')
PY
)
# Extract validation vars (same as original script)...
V_HOST=$(sed -n 's/^HOST=//p' <<<"$CHECK_OUT")
V_FQDN=$(sed -n 's/^FQDN=//p' <<<"$CHECK_OUT")
V_IP=$(sed -n 's/^IP=//p' <<<"$CHECK_OUT")
V_GW=$(sed -n 's/^GW=//p' <<<"$CHECK_OUT")
V_SSH=$(sed -n 's/^SSH=//p' <<<"$CHECK_OUT")
V_ROOT=$(sed -n 's/^ROOTLOGIN=//p' <<<"$CHECK_OUT")
V_PASS=$(sed -n 's/^PASSAUTH=//p' <<<"$CHECK_OUT")
V_ROOTPW=$(sed -n 's/^ROOTPW=//p' <<<"$CHECK_OUT")
V_CLOUD=$(sed -n 's/^CLOUD=//p' <<<"$CHECK_OUT")
V_NTP=$(sed -n 's/^NTP=//p' <<<"$CHECK_OUT")
V_DNS=$(sed -n 's/^DNS=//p' <<<"$CHECK_OUT")
V_GETTY=$(sed -n 's/^GETTY=//p' <<<"$CHECK_OUT")
V_GATEWAY=$(sed -n 's/^GATEWAY_TEST=//p' <<<"$CHECK_OUT")
V_DNS1=$(sed -n 's/^DNS1_TEST=//p' <<<"$CHECK_OUT")
V_DNS2=$(sed -n 's/^DNS2_TEST=//p' <<<"$CHECK_OUT")
V_INTERNET=$(sed -n 's/^INTERNET_TEST=//p' <<<"$CHECK_OUT")

# ============================================================
# VALIDAR RESULTADOS
# ============================================================

ETAPA="VALIDAR_RESULTADOS"
[[ "$V_HOST" == "$HOSTNAME" ]]
[[ "$V_FQDN" == "$FQDN" ]]
[[ "$V_IP" == "$CIDR" ]]
[[ "$V_GW" == "$GW" ]]
[[ "$V_SSH" == "active" ]]
[[ "$V_ROOT" == "yes" ]]
[[ "$V_PASS" == "yes" ]]
[[ "$V_ROOTPW" == "P" ]]
[[ "$V_CLOUD" == "disabled" ]]
[[ "$V_NTP" == "$NTP" ]]
[[ "$V_DNS" == *"$DNS1"* ]]
[[ "$V_DNS" == *"$DNS2"* ]]
[[ "$V_GETTY" == "enabled" ]]
[[ "$V_GATEWAY" == "OK" ]]
[[ "$V_DNS1" == "OK" ]]
[[ "$V_DNS2" == "OK" ]]
[[ "$V_INTERNET" == "OK" ]]

# ============================================================
# VALIDAR PROXMOX FINAL
# ============================================================

ETAPA="VALIDAR_PROXMOX_FINAL"
CFG=$(qm config "$VMID")
VGA=$(awk -F': ' '/^vga:/ {print $2}' <<<"$CFG")
[[ "$VGA" == "std" ]]
! grep -q '^serial0:' <<<"$CFG"
[[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]]
timeout 5 bash -c "<dev/tcp/${IP}/22"
[[ ! -e "$CRED_FILE" ]]

# ============================================================
# RESULTADO FINAL
# ============================================================

trap - ERR
exec 1>&3 2>&4
clear 2>/dev/null || true
echo "============================================================"
echo " ${HOSTNAME} - VM RECRIADA E VALIDADA"
echo "============================================================"
echo
 echo "STATUS............. OK"
echo
 echo "VMID............... ${VMID}"
# (demais informações omitidas para brevidade)

