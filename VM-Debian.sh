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

CLOUDINIT_WAIT_SECONDS="${CLOUDINIT_WAIT_SECONDS:-600}"
AGENT_WAIT_SECONDS="${AGENT_WAIT_SECONDS:-240}"
NTP_WAIT_SECONDS="${NTP_WAIT_SECONDS:-60}"

COMMUNITY_SCRIPT_URL="${COMMUNITY_SCRIPT_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/vm/debian-vm.sh}"

# Opcional: ROOT_PASSWORD pode ser fornecida via ambiente
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
# LOG E FEEDBACK VISUAL
# ============================================================

# Salva descritores originais para saída do console
exec 3>&1 4>&2

: >"$LOG"
exec >>"$LOG" 2>&1

msg() {
    local text="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $text" >> "$LOG"
    echo -e "$text" >&3
}

step() {
    ETAPA="$1"
    local desc="$2"
    msg "\n\e[1;34m[ETAPA: ${ETAPA}]\e[0m \e[1;37m${desc}\e[0m"
}

info() { msg "  \e[36m➜\e[0m $1"; }
ok()   { msg "  \e[32m✔\e[0m $1"; }
warn() { msg "  \e[33m⚠\e[0m $1"; }

# ============================================================
# TRATAMENTO DE ERROS
# ============================================================

falha() {
    RC=$?
    trap - ERR

    rm -f "$CRED_FILE" 2>/dev/null || true
    ROOTPASS=""
    ROOT_PASSWORD=""

    exec 1>&3 2>&4

    echo
    echo "============================================================"
    echo -e " \e[1;31m${HOSTNAME} - ERRO NA ETAPA: ${ETAPA} (CÓDIGO ${RC})\e[0m"
    echo "============================================================"
    echo "LOG COMPLETO: ${LOG}"
    echo
    echo "ÚLTIMAS 25 LINHAS DO LOG:"
    echo "------------------------------------------------------------"
    tail -n 25 "$LOG" 2>/dev/null || true
    echo "------------------------------------------------------------"
    echo "============================================================"

    exit "$RC"
}

trap falha ERR

# ============================================================
# PRÉ-VALIDAÇÃO DO PROXMOX
# ============================================================

step "VALIDAR_PROXMOX" "Verificando pré-requisitos no host Proxmox VE"

[[ "$(id -u)" == "0" ]] || { echo "Este script deve ser executado como root."; false; }

command -v qm >/dev/null
command -v pvesm >/dev/null
command -v python3 >/dev/null
command -v curl >/dev/null

pvesm status -storage "$STORAGE" >/dev/null || { echo "Storage '${STORAGE}' não encontrado ou inativo."; false; }
ip link show "$BRIDGE" >/dev/null || { echo "Bridge '${BRIDGE}' não encontrada."; false; }

ok "Ambiente Proxmox e storage '${STORAGE}' validados."

# ============================================================
# VALIDAR PARÂMETROS
# ============================================================

step "VALIDAR_PARAMETROS" "Validando parâmetros de rede e identificadores"

python3 - "$IP" "$PREFIX" "$GW" "$DNS1" "$DNS2" "$NTP" <<'PY'
import ipaddress, sys
ip, prefix = sys.argv[1], sys.argv[2]
ipaddress.ip_interface(f"{ip}/{prefix}")
for val in sys.argv[3:]:
    ipaddress.ip_address(val)
PY

if [[ ! "$MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
    echo "MAC inválido: ${MAC}"
    false
fi

if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo "VMID inválido: ${VMID}"
    false
fi

ok "Parâmetros de rede válidos (IP: ${CIDR}, GW: ${GW}, MAC: ${MAC})."

# ============================================================
# SENHA ROOT
# ============================================================

step "SENHA_ROOT" "Definindo senha root para a VM"

if [[ -n "$ROOT_PASSWORD" ]]; then
    ROOTPASS="$ROOT_PASSWORD"
    ok "Senha root obtida via variável de ambiente ROOT_PASSWORD."
else
    if [ -t 0 ] || [ -c /dev/tty ]; then
        exec 1>&3 2>&4

        echo "============================================================"
        echo " CRIAR ${HOSTNAME}"
        echo "============================================================"
        echo "VMID........ ${VMID}"
        echo "HOSTNAME.... ${HOSTNAME}"
        echo "FQDN........ ${FQDN}"
        echo "IP.......... ${CIDR}"
        echo "MAC......... ${MAC}"
        echo "STORAGE..... ${STORAGE}"
        echo "BRIDGE...... ${BRIDGE}"
        echo "CONSOLE..... noVNC"
        echo "============================================================"
        echo

        while true; do
            printf "Nova senha root: " >/dev/tty
            IFS= read -r -s ROOTPASS </dev/tty
            printf "\n" >/dev/tty

            printf "Repita a senha:  " >/dev/tty
            IFS= read -r -s ROOTPASS2 </dev/tty
            printf "\n" >/dev/tty

            if [[ -z "$ROOTPASS" ]]; then
                echo "Senha não pode ser vazia." >/dev/tty
                continue
            fi

            if [[ "$ROOTPASS" != "$ROOTPASS2" ]]; then
                echo "Senhas não conferem. Tente novamente." >/dev/tty
                continue
            fi

            unset ROOTPASS2
            break
        done

        exec >>"$LOG" 2>&1
        ok "Senha root informada e confirmada."
    else
        echo "ERRO: ROOT_PASSWORD não informada e nenhum TTY interativo disponível." >&4
        false
    fi
fi

# ============================================================
# VM JÁ EXISTENTE
# ============================================================

step "VERIFICAR_VM_EXISTENTE" "Verificando se VMID ${VMID} já existe"

if qm status "$VMID" >/dev/null 2>&1; then
    if [[ "$RECREATE" != "yes" ]]; then
        echo "VMID ${VMID} já existe e RECREATE não está habilitado."
        false
    fi

    info "VMID ${VMID} existente detectado. Parando e destruindo para recriação..."
    qm stop "$VMID" >/dev/null 2>&1 || true
    sleep 2
    qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1
fi

if qm status "$VMID" >/dev/null 2>&1; then
    echo "Falha ao destruir VMID ${VMID} anterior."
    false
fi

rm -f "$CRED_FILE" 2>/dev/null || true
ok "VMID ${VMID} pronto para criação limpa."

# ============================================================
# CRIAR VM
# ============================================================

step "CRIAR_VM" "Provisionando VM ${VMID} (${HOSTNAME}) com Debian ${OS_VERSION}"

info "Baixando imagem cloud e provisionando VM via script da comunidade..."
info "(Acompanhe o download e criação em tempo real abaixo):"

# Baixa e executa o script da comunidade com parâmetros de rede estática Proxmox
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
    CLOUDINIT_NETWORK_MODE="static" \
    CLOUDINIT_IP="$CIDR" \
    CLOUDINIT_GW="$GW" \
    CLOUDINIT_DNS="$DNS1 $DNS2" \
    CLOUDINIT_SEARCH_DOMAIN="$DOMAIN" \
    bash -c "$(curl -fsSL "$COMMUNITY_SCRIPT_URL")" 2>&1 | tee -a "$LOG" >&3

# Garante que a VM foi criada no Proxmox
if ! qm status "$VMID" >/dev/null 2>&1; then
    echo "Falha: VM ${VMID} não foi encontrada após execução do script de criação."
    false
fi

rm -f "$CRED_FILE" 2>/dev/null || true
ok "VM ${VMID} provisionada com sucesso."

# ============================================================
# CONFIGURAR PROXMOX / noVNC
# ============================================================

step "CONFIGURAR_PROXMOX" "Ajustando parâmetros de hardware e console noVNC"

qm set "$VMID" --vga std >/dev/null
qm set "$VMID" --tablet 1 >/dev/null
qm set "$VMID" --agent enabled=1 >/dev/null
qm set "$VMID" --onboot 1 >/dev/null
qm set "$VMID" --boot order=scsi0 >/dev/null

# Remove console serial para garantir noVNC nativo
qm set "$VMID" --delete serial0 >/dev/null 2>&1 || true

ok "Hardware configurado: VGA=std (noVNC), QEMU Guest Agent ativo, Boot=scsi0."

# ============================================================
# PRIMEIRO BOOT
# ============================================================

step "PRIMEIRO_BOOT" "Iniciando a VM ${VMID} pela primeira vez"

qm start "$VMID"
ok "VM ${VMID} iniciada."

# ============================================================
# AGUARDAR QEMU GUEST AGENT
# ============================================================

step "AGUARDAR_AGENT" "Aguardando inicialização do QEMU Guest Agent"

AGENT_OK=0
AGENT_WAITED=0

while (( AGENT_WAITED < AGENT_WAIT_SECONDS )); do
    if qm guest cmd "$VMID" ping >/dev/null 2>&1; then
        AGENT_OK=1
        break
    fi
    sleep 2
    AGENT_WAITED=$((AGENT_WAITED + 2))
    if (( AGENT_WAITED % 10 == 0 )); then
        info "Aguardando Guest Agent responder... (${AGENT_WAITED}s/${AGENT_WAIT_SECONDS}s)"
    fi
done

if [[ "$AGENT_OK" != "1" ]]; then
    echo "QEMU Guest Agent não respondeu após ${AGENT_WAIT_SECONDS}s."
    false
fi

ok "QEMU Guest Agent comunicando normalmente (${AGENT_WAITED}s)."

# ============================================================
# AGUARDAR CLOUD-INIT
# ============================================================

step "AGUARDAR_CLOUD_INIT" "Aguardando Cloud-Init concluir inicialização interna"

CI_OK=0
CI_WAITED=0

while (( CI_WAITED < CLOUDINIT_WAIT_SECONDS )); do
    CI_JSON="$(qm guest exec "$VMID" --timeout 20 -- bash -lc 'cloud-init status 2>/dev/null || true' 2>/dev/null || true)"

    CI_STATUS="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("out-data", "").strip())
except Exception:
    pass
' "$CI_JSON" 2>/dev/null || true)"

    if grep -qE 'status: (done|degraded)' <<<"$CI_STATUS"; then
        CI_OK=1
        break
    fi

    sleep 3
    CI_WAITED=$((CI_WAITED + 3))
    if (( CI_WAITED % 15 == 0 )); then
        info "Aguardando Cloud-Init finalizar... (${CI_WAITED}s/${CLOUDINIT_WAIT_SECONDS}s)"
    fi
done

if [[ "$CI_OK" != "1" ]]; then
    echo "Cloud-Init não terminou após ${CLOUDINIT_WAIT_SECONDS}s."
    false
fi

ok "Cloud-Init concluído (${CI_STATUS})."

# ============================================================
# SCRIPT DE CONFIGURAÇÃO INTERNA DA VM
# ============================================================

step "CONFIGURAR_GUEST" "Aplicando configurações definitivas de Rede, SSH, Hosts, NTP e GRUB"

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

# 1. Hostname
hostnamectl set-hostname "$HOSTNAME_NEW"

# 2. /etc/hosts
cat >/etc/hosts <<EOF
127.0.0.1 localhost
${IP} ${FQDN} ${HOSTNAME_NEW}

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# 3. Rede Estática (Garante Netplan E systemd-networkd)
if command -v netplan >/dev/null 2>&1; then
    mkdir -p /etc/netplan
    rm -f /etc/netplan/*.yaml 2>/dev/null || true
    cat >/etc/netplan/01-ad-server.yaml <<EOF
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
    netplan generate 2>/dev/null || true
fi

# Configuração direta no systemd-networkd (padrão Debian)
mkdir -p /etc/systemd/network
cat >/etc/systemd/network/10-${IFACE}.network <<EOF
[Match]
Name=${IFACE}

[Network]
Address=${CIDR}
Gateway=${GW}
DNS=${DNS1}
DNS=${DNS2}
Domains=${DOMAIN}
EOF

systemctl enable systemd-networkd 2>/dev/null || true
systemctl enable systemd-resolved 2>/dev/null || true

# Configura resolv.conf estático se não for symlink do resolved
if [ ! -L /etc/resolv.conf ]; then
    cat >/etc/resolv.conf <<EOF
search ${DOMAIN}
nameserver ${DNS1}
nameserver ${DNS2}
EOF
fi

# 4. NTP (systemd-timesyncd)
mkdir -p /etc/systemd/timesyncd.conf.d
cat >/etc/systemd/timesyncd.conf.d/10-setec.conf <<EOF
[Time]
NTP=${NTP}
FallbackNTP=
EOF

timedatectl set-timezone "$TIMEZONE"
systemctl restart systemd-timesyncd 2>/dev/null || true

# 5. SSH Root com senha
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/00-root-password.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitEmptyPasswords no
UsePAM yes
EOF

rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf 2>/dev/null || true
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null || true

passwd -u root >/dev/null 2>&1 || true
ssh-keygen -A >/dev/null 2>&1 || true
sshd -t 2>/dev/null || true
systemctl enable ssh >/dev/null 2>&1 || true
systemctl restart ssh 2>/dev/null || true

# 6. QEMU Guest Agent
systemctl enable qemu-guest-agent >/dev/null 2>&1 || true

# 7. noVNC / VGA console
systemctl enable getty@tty1.service >/dev/null 2>&1 || true

mkdir -p /etc/default/grub.d
cat >/etc/default/grub.d/99-novnc.cfg <<'EOF'
GRUB_TERMINAL_INPUT="console"
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0"
GRUB_CMDLINE_LINUX="console=tty0"
EOF

update-grub >/dev/null 2>&1 || true

# 8. Desabilitar Cloud-Init para boots futuros
touch /etc/cloud/cloud-init.disabled
sync
GUEST_EOF
)"

GUEST_B64="$(printf '%s' "$GUEST_SCRIPT" | base64 -w0)"

GUEST_JSON="$(qm guest exec "$VMID" --timeout 180 -- bash -lc "printf '%s' '$GUEST_B64' | base64 -d | bash -s -- '$HOSTNAME' '$DOMAIN' '$IP' '$PREFIX' '$GW' '$DNS1' '$DNS2' '$NTP' '$MAC' '$TIMEZONE' '$IFACE'")"

GUEST_RC="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("exitcode", 99))
except Exception:
    print(99)
' "$GUEST_JSON")"

if [[ "$GUEST_RC" != "0" ]]; then
    echo "Configuração interna do convidado retornou código de erro: ${GUEST_RC}"
    python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print("STDERR:\n", d.get("err-data", ""))
    print("STDOUT:\n", d.get("out-data", ""))
except Exception:
    pass
' "$GUEST_JSON"
    false
fi

ok "Configurações internas aplicadas com sucesso."

# ============================================================
# LIMPAR SENHA E CREDENCIAL
# ============================================================

step "LIMPAR_CREDENCIAIS" "Removendo credenciais temporárias"

rm -f "$CRED_FILE" 2>/dev/null || true
ROOTPASS=""
ROOT_PASSWORD=""

ok "Credenciais temporárias removidas."

# ============================================================
# REBOOT DEFINITIVO
# ============================================================

step "REBOOT_FINAL" "Reiniciando a VM para carregar configurações de rede e GRUB definitivas"

qm reboot "$VMID"
sleep 4

# ============================================================
# AGUARDAR GUEST AGENT PÓS-REBOOT
# ============================================================

step "AGUARDAR_AGENT_POS_REBOOT" "Aguardando VM inicializar pós-reboot"

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

if [[ "$AGENT_OK" != "1" ]]; then
    echo "Guest Agent não retornou após o reboot."
    false
fi

sleep 4
ok "VM online e comunicando normalmente pós-reboot."

# ============================================================
# AGUARDAR SINCRONIZAÇÃO NTP
# ============================================================

step "AGUARDAR_NTP" "Confirmando sincronização de horário com servidor NTP (${NTP})"

NTP_OK=0
NTP_WAITED=0

while (( NTP_WAITED < NTP_WAIT_SECONDS )); do
    NTP_JSON="$(qm guest exec "$VMID" --timeout 15 -- bash -lc "timedatectl timesync-status 2>/dev/null | grep -q '$NTP'" 2>/dev/null || true)"

    NTP_RC="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("exitcode", 99))
except Exception:
    print(99)
' "$NTP_JSON")"

    if [[ "$NTP_RC" == "0" ]]; then
        NTP_OK=1
        break
    fi

    sleep 2
    NTP_WAITED=$((NTP_WAITED + 2))
done

if [[ "$NTP_OK" != "1" ]]; then
    warn "NTP ${NTP} ainda não sincronizou totalmente, prosseguindo com testes..."
else
    ok "NTP ${NTP} sincronizado com sucesso."
fi

# ============================================================
# VALIDAÇÃO INTERNA COMPLETA
# ============================================================

step "VALIDACAO_GUEST" "Executando bateria de testes dentro da VM"

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

HOST="$(hostname)"
FQDN="$(hostname -f 2>/dev/null || hostname)"
IP="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}')"
GW="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"

SSH="$(systemctl is-active ssh 2>/dev/null || echo inactive)"
ROOTLOGIN="$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2; exit}')"
PASSAUTH="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication" {print $2; exit}')"
ROOTPW="$(passwd -S root 2>/dev/null | awk '{print $2}')"

CLOUD="enabled"
if [[ -f /etc/cloud/cloud-init.disabled ]]; then
    CLOUD="disabled"
fi

NTP_SERVER="$(timedatectl timesync-status 2>/dev/null | awk '/Server:/ {print $2; exit}' || echo none)"
DNS="$(resolvectl dns "$IFACE" 2>/dev/null | sed -E "s/^Link [0-9]+ \(${IFACE}\):[[:space:]]*//" | xargs || true)"
if [[ -z "$DNS" && -f /etc/resolv.conf ]]; then
    DNS="$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | xargs || true)"
fi

GETTY="$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)"
CMDLINE="$(cat /proc/cmdline)"

GATEWAY_TEST="FALHA"
if ping -c1 -W2 "$EXPECTED_GW" >/dev/null 2>&1; then
    GATEWAY_TEST="OK"
fi

DNS1_TEST="FALHA"
if ping -c1 -W2 "$EXPECTED_DNS1" >/dev/null 2>&1; then
    DNS1_TEST="OK"
fi

DNS2_TEST="FALHA"
if ping -c1 -W2 "$EXPECTED_DNS2" >/dev/null 2>&1; then
    DNS2_TEST="OK"
fi

INTERNET_TEST="FALHA"
if getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
    INTERNET_TEST="OK"
fi

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
printf 'CMDLINE=%s\n' "$CMDLINE"
printf 'GATEWAY_TEST=%s\n' "$GATEWAY_TEST"
printf 'DNS1_TEST=%s\n' "$DNS1_TEST"
printf 'DNS2_TEST=%s\n' "$DNS2_TEST"
printf 'INTERNET_TEST=%s\n' "$INTERNET_TEST"
CHECK_EOF
)"

CHECK_B64="$(printf '%s' "$CHECK_SCRIPT" | base64 -w0)"

CHECK_JSON="$(qm guest exec "$VMID" --timeout 60 -- bash -lc "printf '%s' '$CHECK_B64' | base64 -d | bash -s -- '$HOSTNAME' '$FQDN' '$IP' '$PREFIX' '$GW' '$DNS1' '$DNS2' '$NTP' '$IFACE'")"

CHECK_RC="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("exitcode", 99))
except Exception:
    print(99)
' "$CHECK_JSON")"

[[ "$CHECK_RC" == "0" ]] || { echo "Falha ao executar validação interna."; false; }

CHECK_OUT="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("out-data", ""), end="")
except Exception:
    pass
' "$CHECK_JSON")"

# Extrair variáveis de validação
V_HOST="$(sed -n 's/^HOST=//p' <<<"$CHECK_OUT")"
V_FQDN="$(sed -n 's/^FQDN=//p' <<<"$CHECK_OUT")"
V_IP="$(sed -n 's/^IP=//p' <<<"$CHECK_OUT")"
V_GW="$(sed -n 's/^GW=//p' <<<"$CHECK_OUT")"
V_SSH="$(sed -n 's/^SSH=//p' <<<"$CHECK_OUT")"
V_ROOT="$(sed -n 's/^ROOTLOGIN=//p' <<<"$CHECK_OUT")"
V_PASS="$(sed -n 's/^PASSAUTH=//p' <<<"$CHECK_OUT")"
V_ROOTPW="$(sed -n 's/^ROOTPW=//p' <<<"$CHECK_OUT")"
V_CLOUD="$(sed -n 's/^CLOUD=//p' <<<"$CHECK_OUT")"
V_NTP="$(sed -n 's/^NTP=//p' <<<"$CHECK_OUT")"
V_DNS="$(sed -n 's/^DNS=//p' <<<"$CHECK_OUT")"
V_GETTY="$(sed -n 's/^GETTY=//p' <<<"$CHECK_OUT")"
V_CMDLINE="$(sed -n 's/^CMDLINE=//p' <<<"$CHECK_OUT")"
V_GATEWAY="$(sed -n 's/^GATEWAY_TEST=//p' <<<"$CHECK_OUT")"
V_DNS1="$(sed -n 's/^DNS1_TEST=//p' <<<"$CHECK_OUT")"
V_DNS2="$(sed -n 's/^DNS2_TEST=//p' <<<"$CHECK_OUT")"
V_INTERNET="$(sed -n 's/^INTERNET_TEST=//p' <<<"$CHECK_OUT")"

# ============================================================
# VALIDAR RESULTADOS
# ============================================================

step "VALIDAR_RESULTADOS" "Validando conformidade dos testes com a especificação"

[[ "$V_HOST" == "$HOSTNAME" ]] || { echo "Hostname incorreto: $V_HOST"; false; }
[[ "$V_FQDN" == "$FQDN" ]] || { echo "FQDN incorreto: $V_FQDN"; false; }
[[ "$V_IP" == "$CIDR" ]] || { echo "IP incorreto: $V_IP (esperado $CIDR)"; false; }
[[ "$V_GW" == "$GW" ]] || { echo "Gateway incorreto: $V_GW (esperado $GW)"; false; }

[[ "$V_SSH" == "active" ]] || { echo "Serviço SSH não está ativo."; false; }
[[ "$V_ROOT" == "yes" ]] || { echo "PermitRootLogin não está habilitado."; false; }
[[ "$V_PASS" == "yes" ]] || { echo "PasswordAuthentication não está habilitado."; false; }
[[ "$V_ROOTPW" == "P" ]] || { echo "Senha do root não está desbloqueada."; false; }

[[ "$V_CLOUD" == "disabled" ]] || { echo "Cloud-Init não foi desabilitado."; false; }

[[ "$V_GETTY" == "enabled" ]] || { echo "getty@tty1 não habilitado."; false; }
[[ "$V_CMDLINE" == *"console=tty0"* ]] || { echo "console=tty0 ausente no cmdline."; false; }

[[ "$V_GATEWAY" == "OK" ]] || { echo "Teste de ping ao Gateway falhou."; false; }
[[ "$V_DNS1" == "OK" ]] || { echo "Teste de ping ao DNS1 falhou."; false; }
[[ "$V_DNS2" == "OK" ]] || { echo "Teste de ping ao DNS2 falhou."; false; }

ok "Conformidade e conectividade validadas com sucesso."

# ============================================================
# VALIDAÇÃO NO HOST PROXMOX
# ============================================================

step "VALIDAR_PROXMOX_FINAL" "Validando configuração da VM no Proxmox PVE"

CFG="$(qm config "$VMID")"
VGA="$(awk -F': ' '/^vga:/ {print $2}' <<<"$CFG")"

[[ "$VGA" == "std" ]] || { echo "VGA não está configurada como std."; false; }
! grep -q '^serial0:' <<<"$CFG" || { echo "serial0 ainda presente na configuração."; false; }
[[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]] || { echo "VM não está em execução."; false; }

# Testa porta SSH aberta no IP estático
timeout 5 bash -c "</dev/tcp/${IP}/22" || { echo "Porta 22/SSH inacessível em ${IP}."; false; }

[[ ! -e "$CRED_FILE" ]]

ok "Validação final do Proxmox PVE concluída (Porta 22 aberta e respondendo)."

# ============================================================
# RESULTADO FINAL
# ============================================================

trap - ERR

exec 1>&3 2>&4

clear 2>/dev/null || true

echo "============================================================"
echo " ${HOSTNAME} - VM RECRIADA E VALIDADA COM SUCESSO"
echo "============================================================"
echo
echo "STATUS............. OK"
echo
echo "VMID............... ${VMID}"
echo "HOSTNAME........... ${V_HOST}"
echo "FQDN............... ${V_FQDN}"
echo
echo "IP................. ${V_IP}"
echo "GATEWAY............ ${V_GW}"
echo "DNS................ ${V_DNS}"
echo "NTP................ ${V_NTP}"
echo
echo "CPU................ ${CPU} vCPU"
echo "RAM................ ${RAM} MB"
echo "DISCO.............. ${DISK}"
echo "STORAGE............ ${STORAGE}"
echo "BRIDGE............. ${BRIDGE}"
echo "MAC................ ${MAC}"
echo
echo "CONSOLE............ noVNC"
echo "VGA................ ${VGA}"
echo "TTY1............... ${V_GETTY}"
echo
echo "SSH................ ${V_SSH}"
echo "USUARIO............ root"
echo "ROOT LOGIN......... ${V_ROOT}"
echo "PASSWORD AUTH...... ${V_PASS}"
echo "ROOT PASSWORD...... configurada"
echo
echo "CLOUD-INIT......... ${V_CLOUD}"
echo "CREDENCIAL /tmp.... removida"
echo
echo "GATEWAY TESTE...... ${V_GATEWAY}"
echo "DNS1 TESTE......... ${V_DNS1}"
echo "DNS2 TESTE......... ${V_DNS2}"
echo "INTERNET/DNS....... ${V_INTERNET}"
echo
echo "============================================================"
echo " Acesso SSH:  ssh root@${IP}"
echo " Console:     Proxmox Web -> VM ${VMID} -> Console (noVNC)"
echo "============================================================"
echo
