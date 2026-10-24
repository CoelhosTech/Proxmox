#!/usr/bin/env bash
# =============================================================================
# Samba‑AD.sh – Provisionamento automatizado de controlador de domínio AD
#               (Samba 4) em servidores Debian (primary / secondary).
#
# Uso típico (variáveis de ambiente):
#   env ROLE=PRIMARY \
#       PRIMARY_HOSTNAME=srvAD01 PRIMARY_IP=192.168.50.4 \
#       SECONDARY_HOSTNAME=srvAD02 SECONDARY_IP=192.168.50.5 \
#       DOMAIN=ad.setec.sp.gov.br NETBIOS=SETEC PREFIX=24 GW=192.168.50.1 \
#       PIHOLE1=192.168.50.2 PIHOLE2=192.168.50.3 NTP=192.168.50.1 \
#       REVERSE_ZONE=50.168.192.in-addr.arpa \
#   bash -c "$(curl -fsSL https://<YOUR‑REPO>/Samba-AD.sh)"
#
# O script aceita ROLE=PRIMARY ou ROLE=SECONDARY.
#   * PRIMARY – provisiona o primeiro DC e cria a zona DNS reversa.
#   * SECONDARY – realiza o join ao DC já existente e habilita a réplica.
#
# Todos os passos são exibidos em “status blocks” compactos e coloridos.
# Ao final, um diagnóstico rápido valida a configuração.
# =============================================================================

set -euo pipefail

# ------------------------------- Helpers ------------------------------------
C_RED="\e[31m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_BLUE="\e[34m"
C_BOLD="\e[1m"; C_RESET="\e[0m"

log() {
    local level=$1 msg=$2
    case "$level" in
        INFO)    echo -e "${C_BLUE}[${level}]${C_RESET} $msg" ;;
        OK)      echo -e "${C_GREEN}[${level}]${C_RESET} $msg" ;;
        WARN)    echo -e "${C_YELLOW}[${level}]${C_RESET} $msg" ;;
        ERROR)   echo -e "${C_RED}[${level}]${C_RESET} $msg" ;;
    esac
}

die() { log "ERROR" "$1"; exit 1; }

# --------------------------- Input validation -------------------------------
[[ -z "${ROLE:-}" ]] && die "Variável ROLE (PRIMARY|SECONDARY) não informada."
ROLE=$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')
[[ "$ROLE" != "PRIMARY" && "$ROLE" != "SECONDARY" ]] && die "ROLE deve ser PRIMARY ou SECONDARY."

# Variáveis obrigatórias (algumas só são usadas pelo primary)
: "${DOMAIN:?VAR não informada}"
: "${NETBIOS:?VAR não informada}"
: "${PREFIX:?VAR não informada}"
: "${GW:?VAR não informada}"
: "${PIHOLE1:?VAR não informada}"
: "${PIHOLE2:?VAR não informada}"
: "${NTP:?VAR não informada}"
: "${REVERSE_ZONE:?VAR não informada}"

# Primary variables (necessárias só quando ROLE=PRIMARY)
if [[ "$ROLE" == "PRIMARY" ]]; then
    : "${PRIMARY_HOSTNAME:?VAR não informada}"
    : "${PRIMARY_IP:?VAR não informada}"
fi

# Secondary variables (necessárias só quando ROLE=SECONDARY)
if [[ "$ROLE" == "SECONDARY" ]]; then
    : "${SECONDARY_HOSTNAME:?VAR não informada}"
    : "${SECONDARY_IP:?VAR não informada}"
    : "${PRIMARY_HOSTNAME:?VAR não informada}"
    : "${PRIMARY_IP:?VAR não informada}"
fi

# --------------------------- Prompt admin credentials -----------------------
echo -e "\n${C_BOLD}=== Credenciais de administrador do AD ===${C_RESET}"
read -rp "Nome do usuário administrador (ex: Administrator): " AD_ADMIN_USER
read -rsp "Senha do administrador: " AD_ADMIN_PASS
echo    # newline

# --------------------------- Pre‑install packages ---------------------------
log INFO "Instalando dependências (samba, krb5, winbind, dnsutils, ntp)..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -yqq \
    samba samba-dsdb-modules samba-vfs-modules \
    krb5-user winbind dnsutils ntp

# --------------------------------------------------------------
# Configurações de rede (assume que o IP está estático via DHCP reserva)
# --------------------------------------------------------------
log INFO "Configurando resolvers DNS (pihole primário)..."
cat > /etc/resolv.conf <<EOF
nameserver $PIHOLE1
nameserver $PIHOLE2
search $DOMAIN
EOF

log INFO "Sincronizando relógio com NTP ($NTP)..."
sed -i.bak "s/^pool .*/pool $NTP iburst/" /etc/ntp.conf
systemctl restart ntp

# ==============================================================
#               Funções específicas de ROLE
# ==============================================================

provision_primary() {
    log INFO "Provisionando controlador AD PRIMARY ($PRIMARY_HOSTNAME)..."

    samba-tool domain provision \
        --realm="${DOMAIN^^}" \
        --domain="${NETBIOS^^}" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="$AD_ADMIN_PASS" \
        --use-rfc2307 \
        --option="dns forwarder = $PIHOLE1" \
        --option="netbios name = ${NETBIOS^^}" \
        --option="realm = ${DOMAIN^^}" \
        --option="workgroup = ${NETBIOS^^}" \
        --option="idmap config * : backend = tdb" \
        --option="idmap config * : range = 2000-9999" \
        --option="idmap config ${NETBIOS^^} : backend = rid" \
        --option="idmap config ${NETBIOS^^} : range = 10000-999999" \
        --option="template homedir = /home/%U" \
        --option="template shell = /bin/bash" \
        --option="log level = 2"

    log OK "Controlador PRIMARY provisionado."

    # Configura zona reversa
    log INFO "Criando zona DNS reversa $REVERSE_ZONE..."
    samba-tool dns zonecreate "$PRIMARY_IP" "$REVERSE_ZONE" -U "$AD_ADMIN_USER%$AD_ADMIN_PASS"
    log OK "Zona reversa criada."

    # Habilita serviços
    log INFO "Ativando e iniciando serviços Samba..."
    systemctl enable samba-ad-dc
    systemctl restart samba-ad-dc
    log OK "Serviços iniciados."

    # Testes básicos
    log INFO "Validando configuração (net ads testjoin)..."
    net ads testjoin -U "$AD_ADMIN_USER%$AD_ADMIN_PASS" && log OK "Testjoin OK"
}

join_secondary() {
    log INFO "Ingressando como SECONDARY ($SECONDARY_HOSTNAME) ao DC $PRIMARY_HOSTNAME..."

    net ads join -U "$AD_ADMIN_USER%$AD_ADMIN_PASS" -S "$PRIMARY_HOSTNAME"
    log OK "Join concluído."

    # Configura replicação automática (Samba já cuida)
    log INFO "Habilitando replicação (samba-tool drs replicate)..."
    samba-tool drs replicate "$SECONDARY_HOSTNAME" "$PRIMARY_HOSTNAME" "$NETBIOS" -U "$AD_ADMIN_USER%$AD_ADMIN_PASS"
    log OK "Replicação inicial realizada."

    # Inicia serviço DC em modo replica
    log INFO "Iniciando serviço samba-ad-dc (replica)..."
    systemctl enable samba-ad-dc
    systemctl restart samba-ad-dc
    log OK "Serviço replica iniciado."

    # Teste de replicação
    log INFO "Verificando estado de replicação..."
    samba-tool drs showrepl "$SECONDARY_HOSTNAME" -U "$AD_ADMIN_USER%$AD_ADMIN_PASS"
    log OK "Replicação verificada."
}

# ==============================================================
#                         Execução
# ==============================================================

if [[ "$ROLE" == "PRIMARY" ]]; then
    provision_primary
else
    join_secondary
fi

# --------------------------- Pós‑configuração ---------------------------
log INFO "Executando diagnóstico final..."

# 1️⃣ Verifica se o DNS interno responde autoritativamente
log INFO "Checando resolução DNS interna..."
host -t A "$(hostname -s).$DOMAIN" 2>/dev/null && log OK "DNS interno OK"

# 2️⃣ Verifica kerberos
log INFO "Testando Kerberos (kinit)..."
echo "$AD_ADMIN_PASS" | kinit "$AD_ADMIN_USER@${DOMAIN^^}" && log OK "Kerberos OK"

# 3️⃣ Verifica serviço LDAP
log INFO "Consultando LDAP (ldapsearch)..."
ldapsearch -x -LLL -H ldaps://$(hostname -s) -b "dc=$(echo $DOMAIN | tr '.' ',dc=')" -D "$AD_ADMIN_USER@${DOMAIN^^}" -w "$AD_ADMIN_PASS" sAMAccountName | head -n 5 && log OK "LDAP OK"

log INFO "=== CONCLUSÃO ==="
log OK "Provisionamento concluído com sucesso."
log INFO "Caso algum bloco acima tenha sinalizado WARN/ERROR, reveja a mensagem e ajuste manualmente."

exit 0

