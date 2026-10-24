#!/usr/bin/env bash
# =============================================================================
# Samba-AD.sh – Production‑grade provisioning of Samba AD DC (Primary/Secondary)
# =============================================================================
# This script is intended for **production** environments. It performs:
#   • Dependency installation (samba‑dc, krb5, winbind, dnsutils, chrony, …)
#   • Secure configuration of chrony (NTP client)
#   • Primary DC provisioning with internal DNS and reverse zone
#   • Secondary DC join with immediate replication
#   • Idempotent checks – safe to re‑run without breaking existing setup
#   • Basic validation at the end (testjoin, drs replication, DNS queries)
# =============================================================================

set -euo pipefail

# ------------------------------- Helpers ------------------------------------
C_RED="\e[31m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_BLUE="\e[34m"; C_RESET="\e[0m"
log() {
    local level=$1 msg=$2
    case "$level" in
        INFO)  echo -e "${C_BLUE}[${level}]${C_RESET} $msg" ;;
        OK)    echo -e "${C_GREEN}[${level}]${C_RESET} $msg" ;;
        WARN)  echo -e "${C_YELLOW}[${level}]${C_RESET} $msg" ;;
        ERROR) echo -e "${C_RED}[${level}]${C_RESET} $msg" ;;
    esac
}

die() { log ERROR "$1"; exit 1; }

# --------------------------- Preconditions ---------------------------------
[[ $(id -u) -eq 0 ]] || die "Este script deve ser executado como root."

# --------------------------- Input validation -------------------------------
: "${ROLE:?Variável ROLE (PRIMARY|SECONDARY) não informada.}"; ROLE=$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')
[[ "$ROLE" == "PRIMARY" || "$ROLE" == "SECONDARY" ]] || die "ROLE deve ser PRIMARY ou SECONDARY."

# Required environment variables – fail fast if missing
required_vars=(DOMAIN NETBIOS PRIMARY_HOSTNAME PRIMARY_IP SECONDARY_HOSTNAME SECONDARY_IP PREFIX GW PIHOLE1 PIHOLE2 NTP REVERSE_ZONE)
for var in "${required_vars[@]}"; do
    [[ -n "${!var:-}" ]] || die "Variável $var não informada."
done

# Prompt for AD admin credentials (secure input)
read -p "Nome do usuário administrador AD (ex.: Administrator): " AD_ADMIN_USER
read -s -p "Senha do administrador AD: " AD_ADMIN_PASS
echo

# --------------------------- Functions --------------------------------------
install_packages() {
    log INFO "Instalando dependências…"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq \
        samba samba-dc krb5-config winbind dnsutils chrony \
        ntpdate openssl acl >/dev/null
    log OK "Dependências instaladas."
}

configure_chrony() {
    log INFO "Configurando chrony (NTP)…"
    cat > /etc/chrony/chrony.conf <<EOF
pool 2.debian.pool.ntp.org iburst
server $NTP iburst
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
EOF
    systemctl restart chrony && systemctl enable chrony >/dev/null
    log OK "Chrony configurado e habilitado."
}

configure_dns_forwarders() {
    # Used by Samba provisioning – forward DNS to Pi‑hole servers
    echo "dns forwarder = $PIHOLE1 $PIHOLE2" >> /etc/samba/smb.conf
}

provision_primary() {
    log INFO "Provisionando controlador PRIMARY…"
    # Idempotent: skip if /etc/samba/smb.conf already contains a domain section
    if grep -q "realm = ${DOMAIN^^}" /etc/samba/smb.conf 2>/dev/null; then
        log WARN "Controlador já provisionado – pulando provisionamento."
        return
    fi

    samba-tool domain provision \
        --realm="${DOMAIN^^}" \
        --domain="${NETBIOS}" \
        --adminpass="$AD_ADMIN_PASS" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --use-rfc2307 \
        --option="log level = 3" \
        --option="netbios name = $PRIMARY_HOSTNAME" \
        --option="interfaces = lo $PRIMARY_IP" \
        --option="bind interfaces only = yes"
    log OK "Controlador PRIMARY provisionado."

    # Reverse zone creation (idempotent)
    if ! samba-tool dns zonelist ${PRIMARY_HOSTNAME} -U"$AD_ADMIN_USER%$AD_ADMIN_PASS" | grep -q "$REVERSE_ZONE"; then
        samba-tool dns zonecreate ${PRIMARY_HOSTNAME} $REVERSE_ZONE -U"$AD_ADMIN_USER%$AD_ADMIN_PASS"
        log OK "Zona DNS reversa $REVERSE_ZONE criada."
    else
        log WARN "Zona reversa $REVERSE_ZONE já existente – pulando."
    fi

    configure_dns_forwarders

    # Enable and start AD services
    systemctl enable samba-ad-dc nmbd smbd winbind >/dev/null
    systemctl restart samba-ad-dc nmbd smbd winbind >/dev/null
    log OK "Serviços Samba AD iniciados."
}

join_secondary() {
    log INFO "Ingressando como controlador SECONDARY…"
    # Wait for primary to be reachable (simple TCP check on LDAP port 389)
    timeout=300
    while ! timeout 1 nc -z $PRIMARY_IP 389; do
        ((timeout-=5))
        [[ $timeout -le 0 ]] && die "Primary DC não respondeu na porta LDAP (389)."
        sleep 5
    done
    log OK "Primary DC está online – continuando join."

    # Idempotent: check if already member
    if test -f /etc/samba/smb.conf && grep -q "realm = ${DOMAIN^^}" /etc/samba/smb.conf; then
        log WARN "Controlador SECONDARY já unido – pulando join."
        return
    fi

    samba-tool domain join ${DOMAIN^^} DC \
        -U"$AD_ADMIN_USER%$AD_ADMIN_PASS" \
        --dns-backend=SAMBA_INTERNAL \
        --option="netbios name = $SECONDARY_HOSTNAME" \
        --option="interfaces = lo $SECONDARY_IP" \
        --option="bind interfaces only = yes"
    log OK "Ingressado no domínio como SECONDARY."

    configure_dns_forwarders
    systemctl enable samba-ad-dc nmbd smbd winbind >/dev/null
    systemctl restart samba-ad-dc nmbd smbd winbind >/dev/null
    log OK "Serviços Samba AD SECONDARY iniciados."
}

validate_configuration() {
    log INFO "Validando configuração…"
    net ads testjoin && log OK "net ads testjoin OK" || log WARN "net ads testjoin falhou"
    samba-tool drs showrepl $HOSTNAME -U"$AD_ADMIN_USER%$AD_ADMIN_PASS" && log OK "Replication status OK" || log WARN "Replication status problem"
    # Forward lookup test (example)
    host "$PRIMARY_HOSTNAME.$DOMAIN" && log OK "Forward DNS OK" || log WARN "Forward DNS falhou"
    # Reverse lookup test (example)
    host "$PRIMARY_IP" && log OK "Reverse DNS OK" || log WARN "Reverse DNS falhou"
    log INFO "Validação concluída."
}

# --------------------------- Main flow ------------------------------------
install_packages
configure_chrony

if [[ "$ROLE" == "PRIMARY" ]]; then
    provision_primary
else
    join_secondary
fi

validate_configuration
log OK "Provisionamento Samba‑AD concluído com sucesso."
exit 0
