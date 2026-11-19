#!/bin/bash
# certxray.sh - TURBONET XRAY V1.1
# Correções aplicadas:
#   - Detecção dinâmica do usuário/grupo do xray.service (_detect_xray_owner)
#   - Permissões 750/640 root:$XRAY_GROUP em $SSL_DIR e privkey.pem, e 644 root:root em fullchain.pem
#   - Mesma detecção dinâmica replicada dentro do renew_cert.sh gerado para o cron
#   - Garantido ensure_cmd jq antes de atualizar serverName no config.json
#   - Restaura estado ativo do xray caso tenha sido parado para validação HTTP-01 na porta 80
#   - Cron com jitter aleatório — evita rate limiting no Let's Encrypt

set -Eeuo pipefail

RAW_INPUT="$*"
DOMAIN="$(echo "$RAW_INPUT" | awk '{print $NF}' | tr -d '[:space:][:cntrl:]')"

SSL_DIR="/opt/TurbonetCoreSSL"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LE_DIR=""
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"
ACTIVE_DOMAIN_FILE="/opt/XrayTools/active_domain"
LOG_FILE="/tmp/certxray.log"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

YB='\033[1;33m'
RB='\033[1;31m'
GB='\033[1;32m'
CB='\033[1;36m'
BG_RED='\033[41;1;37m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- DETECÇÃO DE DISTRO ---
_PKG_MANAGER=""
_APT_UPDATED=0
_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else echo -e "${RB}❌ Gerenciador de pacotes não detectado.${RESET}"; exit 1; fi
}

ensure_cmd() {
    local cmd="$1" pkg="$2"
    command -v "$cmd" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >>"$LOG_FILE" 2>&1 || true; _APT_UPDATED=1; }
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
}

_detect_xray_owner() {
    local svc_user=""
    if command -v systemctl &>/dev/null; then
        svc_user=$(systemctl show -p User --value xray 2>/dev/null || true)
    fi
    svc_user="${svc_user:-nobody}"
    if ! id "$svc_user" &>/dev/null; then
        svc_user="root"
    fi
    XRAY_USER="$svc_user"
    XRAY_GROUP="$(id -gn "$XRAY_USER")"
}

# --- VALIDAÇÃO DE DOMÍNIO (RFC 1123) ---
validate_domain() {
    local d="${1:-}"
    [ -n "$d" ] || return 1
    [[ "$d" =~ ^[0-9.]+$ ]] && return 1
    [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# --- IP PÚBLICO COM HTTPS E TIMEOUT ---
get_public_ip() {
    curl -4fsSL --max-time 10 --connect-timeout 5 \
        "https://icanhazip.com" 2>/dev/null \
    || curl -4fsSL --max-time 10 --connect-timeout 5 \
        "https://api.ipify.org" 2>/dev/null \
    || echo ""
}

dns_points_to_vps() {
    local ip="$1"
    [ -n "$ip" ] || return 1
    local ans
    ans="$(dig +short A "$DOMAIN" 2>/dev/null || true)"
    echo "$ans" | grep -qx "$ip"
}

ensure_ssl_dir() {
    mkdir -p "$SSL_DIR"
    [ -d "$SSL_DIR" ] || { echo -e "${RB}❌ Não foi possível criar ${SSL_DIR}${RESET}"; return 1; }
}

# Tabela de permissões:
#   $SSL_DIR/          → 750 root:$XRAY_GROUP  (Xray atravessa o diretório, sem escrita)
#   privkey.pem        → 640 root:$XRAY_GROUP  (chave privada restrita ao grupo do Xray)
#   fullchain.pem      → 644 root:root         (certificado público legível)
#   renew_cert.sh      → 700 root:root         (executado como root via cron)
apply_perms() {
    ensure_ssl_dir || return 1
    _detect_xray_owner
    chmod 750 "$SSL_DIR"
    chown "root:${XRAY_GROUP}" "$SSL_DIR"
    if [ -f "$SSL_DIR/privkey.pem" ]; then
        chmod 640 "$SSL_DIR/privkey.pem"
        chown "root:${XRAY_GROUP}" "$SSL_DIR/privkey.pem"
    fi
    if [ -f "$SSL_DIR/fullchain.pem" ]; then
        chmod 644 "$SSL_DIR/fullchain.pem"
        chown root:root "$SSL_DIR/fullchain.pem"
    fi
}

# --- BACKUP DOS CERTS ATUAIS ---
backup_existing_certs() {
    if [ -f "$SSL_DIR/fullchain.pem" ] || [ -f "$SSL_DIR/privkey.pem" ]; then
        cp -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem.bak" 2>/dev/null || true
        cp -f "$SSL_DIR/privkey.pem"   "$SSL_DIR/privkey.pem.bak"   2>/dev/null || true
    fi
}

restore_cert_backup() {
    if [ -f "$SSL_DIR/fullchain.pem.bak" ] && [ -f "$SSL_DIR/privkey.pem.bak" ]; then
        cp -f "$SSL_DIR/fullchain.pem.bak" "$SSL_DIR/fullchain.pem"
        cp -f "$SSL_DIR/privkey.pem.bak"   "$SSL_DIR/privkey.pem"
        apply_perms
        echo -e "${YB}Certificado anterior restaurado.${RESET}"
    fi
}

make_selfsigned() {
    echo -e "${YB}>>> Gerando certificado AUTO-ASSINADO...${RESET}"
    ensure_cmd openssl openssl
    ensure_ssl_dir || exit 1

    local cn_value="$DOMAIN"
    echo ""
    echo -e "${YB}CN do certificado (usado como SNI no app cliente):${RESET}"
    echo " [1] Domínio/SNI configurado: ${DOMAIN}"
    echo " [2] IP público da VPS (recomendado para HTTP Injection)"
    read -rp "Opção [1/2, Enter=1]: " cn_opt
    if [ "${cn_opt:-1}" = "2" ]; then
        echo -n "Detectando IP público... "
        local pub_ip
        pub_ip=$(curl -4fsSL --max-time 8 https://icanhazip.com 2>/dev/null || \
                 curl -4fsSL --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
        if [ -n "$pub_ip" ]; then
            cn_value="$pub_ip"
            echo -e "${GB}${pub_ip}${RESET}"
        else
            echo -e "${YB}Falha — usando domínio.${RESET}"
        fi
    fi

    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=TurboNet/OU=VPN/CN=${cn_value}" \
        -keyout "$SSL_DIR/privkey.pem" \
        -out "$SSL_DIR/fullchain.pem" >>"$LOG_FILE" 2>&1; then
        echo -e "${RB}❌ Falha ao gerar certificado autoassinado.${RESET}"
        restore_cert_backup
        exit 1
    fi

    apply_perms

    # Atualizar serverName no config.json caso já exista uma configuração ativa
    if [ -f "$CONFIG_PATH" ]; then
        ensure_cmd jq jq
        if jq empty "$CONFIG_PATH" 2>/dev/null; then
            local tmp_cfg; tmp_cfg=$(mktemp /tmp/xray_cfg_cert_XXXXXX.json)
            if jq --arg sn "$cn_value" \
                '(.inbounds[] | select(.tag=="inbound-turbonet") |
                 .streamSettings.tlsSettings.serverName) = $sn' \
                "$CONFIG_PATH" > "$tmp_cfg" 2>/dev/null && \
                jq empty "$tmp_cfg" 2>/dev/null; then
                mv -f "$tmp_cfg" "$CONFIG_PATH"
                _detect_xray_owner
                chmod 750 "$(dirname "$CONFIG_PATH")"
                chown "root:${XRAY_GROUP}" "$(dirname "$CONFIG_PATH")"
                chmod 640 "$CONFIG_PATH"
                chown "root:${XRAY_GROUP}" "$CONFIG_PATH"
                echo -e "${GB}✅ serverName atualizado para: ${cn_value}${RESET}"
            else
                rm -f "$tmp_cfg"
            fi
        fi
    fi

    echo -e "${GB}✅ Certificado autoassinado criado em:${RESET} ${CB}$SSL_DIR${RESET}"
    echo -e " ${YB}CN/SNI:${RESET} ${CB}${cn_value}${RESET}"
    echo -e " ${YB}Validade:${RESET} 3650 dias (10 anos)"
    echo ""
    echo -e " ${YB}⚠  No app cliente configure:${RESET}"
    echo -e "  SNI/serverName: ${CB}${cn_value}${RESET}"
    echo -e "  allowInsecure:  ${CB}true${RESET} (cert autoassinado)"
}

install_letsencrypt() {
    echo -e "${YB}>>> Preparando Let's Encrypt...${RESET}"
    ensure_cmd certbot certbot
    ensure_cmd fuser psmisc
    ensure_ssl_dir || return 1

    echo -e "${YB}Parando serviços na porta 80...${RESET}"
    systemctl stop xray  >/dev/null 2>&1 || true
    systemctl stop nginx >/dev/null 2>&1 || true
    fuser -k 80/tcp >/dev/null 2>&1 || true
    sleep 2

    LE_DIR="/etc/letsencrypt/live/$DOMAIN"
    rm -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true

    local CERT_FAIL=0
    certbot certonly --standalone -d "$DOMAIN" \
        --register-unsafely-without-email --agree-tos --non-interactive \
        >>"$LOG_FILE" 2>&1 || CERT_FAIL=1

    if [ "$CERT_FAIL" -ne 0 ] || [ ! -f "$LE_DIR/fullchain.pem" ] || [ ! -f "$LE_DIR/privkey.pem" ]; then
        return 1
    fi

    cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
    cp -f "$LE_DIR/privkey.pem"   "$SSL_DIR/privkey.pem"
    apply_perms

    local CRON_MIN CRON_HOUR
    CRON_MIN=$(( RANDOM % 60 ))
    CRON_HOUR=$(( 2 + RANDOM % 4 ))

    # Script de renovação gerado com detecção dinâmica do grupo do xray.service
    cat > "$RENEW_SCRIPT" <<RENEW_EOF
#!/bin/bash
# renew_cert.sh — gerado por certxray.sh V1.1
set -Eeuo pipefail
LOG="/tmp/renew_cert.log"
: > "\$LOG"
echo "=== Renovação: \$(date) ===" >> "\$LOG"

systemctl stop xray  >/dev/null 2>&1 || true
systemctl stop nginx >/dev/null 2>&1 || true
fuser -k 80/tcp >/dev/null 2>&1 || true

if ! certbot renew --quiet >>"\$LOG" 2>&1; then
    echo "FALHA: certbot renew falhou" >> "\$LOG"
    systemctl start xray >/dev/null 2>&1 || true
    exit 1
fi

XRAY_SVC_USER=\$(systemctl show -p User --value xray 2>/dev/null || true)
XRAY_SVC_USER="\${XRAY_SVC_USER:-nobody}"
id "\$XRAY_SVC_USER" &>/dev/null || XRAY_SVC_USER="root"
XRAY_SVC_GROUP=\$(id -gn "\$XRAY_SVC_USER")

mkdir -p "${SSL_DIR}"
cp -f "${LE_DIR}/fullchain.pem" "${SSL_DIR}/fullchain.pem"
cp -f "${LE_DIR}/privkey.pem"   "${SSL_DIR}/privkey.pem"

chmod 750 "${SSL_DIR}"
chown "root:\${XRAY_SVC_GROUP}" "${SSL_DIR}"
chmod 640 "${SSL_DIR}/privkey.pem"
chown "root:\${XRAY_SVC_GROUP}" "${SSL_DIR}/privkey.pem"
chmod 644 "${SSL_DIR}/fullchain.pem"
chown root:root "${SSL_DIR}/fullchain.pem"

systemctl restart xray >/dev/null 2>&1 || true

_wait_xray_active() {
    local tries=5
    while [ "\$tries" -gt 0 ]; do
        systemctl is-active --quiet xray 2>/dev/null && return 0
        sleep 1
        tries=\$(( tries - 1 ))
    done
    return 1
}

if ! _wait_xray_active; then
    echo "AVISO: Xray não ficou ativo após renovação!" >> "\$LOG"
    journalctl -u xray -n 20 --no-pager >> "\$LOG" 2>/dev/null || true
    exit 1
fi

echo "Renovação concluída com sucesso." >> "\$LOG"
RENEW_EOF

    chmod 700 "$RENEW_SCRIPT"
    chown root:root "$RENEW_SCRIPT"

    ( crontab -l 2>/dev/null | grep -v "renew_cert.sh"
      echo "${CRON_MIN} ${CRON_HOUR} 1 * * $RENEW_SCRIPT >>/tmp/renew_cert.log 2>&1"
    ) | crontab -

    echo -e "${GB}✅ Let's Encrypt instalado. Renovação agendada para dia 1 às ${CRON_HOUR}:$(printf '%02d' $CRON_MIN).${RESET}"
    return 0
}

# --- MAIN ---
: > "$LOG_FILE"
clear
echo -e "${YB}====================================================${RESET}"
echo -e "${YB}         GERENCIADOR DE CERTIFICADOS SSL            ${RESET}"
echo -e "${YB}====================================================${RESET}"
echo ""

if [ -z "${DOMAIN:-}" ] || [ "$DOMAIN" = "certxray.sh" ]; then
    read -rp "Digite o domínio: " DOMAIN
    DOMAIN="$(echo "${DOMAIN:-}" | tr -d '[:space:][:cntrl:]')"
fi

[ -n "${DOMAIN:-}" ] || { echo -e "${RB}❌ Domínio vazio.${RESET}"; exit 1; }

if ! validate_domain "$DOMAIN"; then
    echo -e "${RB}❌ Domínio inválido: '${DOMAIN}'${RESET}"
    echo -e "${YB}   Use o formato: exemplo.com ou sub.exemplo.com${RESET}"
    exit 1
fi

mkdir -p /opt/XrayTools 2>/dev/null || true
echo "$DOMAIN" > "$ACTIVE_DOMAIN_FILE" 2>/dev/null || true

echo -e "${YB}DOMÍNIO ALVO:${RESET} ${CB}$DOMAIN${RESET}"
echo ""
echo -e "${YB}TIPO DE CERTIFICADO:${RESET}"
echo ""
echo -e "${YB} [1] LET'S ENCRYPT (Oficial)${RESET}"
echo -e "${RB}     ⚠ Requer porta 80 aberta e DNS apontando para esta VPS${RESET}"
echo ""
echo -e "${YB} [2] AUTO-ASSINADO (Local)${RESET}"
echo -e "${GB}     ✅ Sem porta 80 / Funciona com CDN (Azion/Cloudflare)${RESET}"
echo ""
echo -e "${YB}====================================================${RESET}"
read -rp "OPÇÃO [1/2]: " cert_opt

ensure_ssl_dir
backup_existing_certs

XRAY_WAS_ACTIVE=0
systemctl is-active --quiet xray 2>/dev/null && XRAY_WAS_ACTIVE=1

_restore_xray_if_needed() {
    if [ "$XRAY_WAS_ACTIVE" -eq 1 ] && [ -f "$CONFIG_PATH" ]; then
        systemctl restart xray >/dev/null 2>&1 || true
    fi
}

case "${cert_opt:-2}" in
  1)
    clear
    echo -e "${BG_RED}             ⚠  LEIA COM ATENÇÃO  ⚠             ${RESET}"
    echo ""
    echo -e "${YB}LET'S ENCRYPT (HTTP-01) requer:${RESET}"
    echo -e " 1) ${RB}DNS do domínio apontando para o IP desta VPS${RESET}"
    echo -e " 2) ${RB}Porta 80 aberta na internet${RESET}"
    echo ""

    ensure_cmd dig  dnsutils
    ensure_cmd curl curl

    VPS_IP="$(get_public_ip)"
    echo -e "${YB}IP público desta VPS:${RESET} ${CB}${VPS_IP:-"(não detectado)"}${RESET}"
    echo -e "${YB}IPs no DNS do domínio:${RESET}"
    dig +short A "$DOMAIN" 2>/dev/null || echo "  (falha na consulta DNS)"
    echo ""

    if ! dns_points_to_vps "${VPS_IP:-}"; then
        echo -e "${RB}⚠  DNS NÃO aponta para esta VPS — Let's Encrypt provavelmente falhará.${RESET}"
        echo ""
        echo " [1] Tentar Let's Encrypt mesmo assim"
        echo " [2] Gerar autoassinado (recomendado)"
        echo " [0] Cancelar"
        read -rp "Opção: " fallback_opt
        case "$fallback_opt" in
            2) make_selfsigned
               rm -f "$SSL_DIR/fullchain.pem.bak" "$SSL_DIR/privkey.pem.bak" 2>/dev/null || true
               _restore_xray_if_needed
               exit 0 ;;
            0) restore_cert_backup; _restore_xray_if_needed; exit 0 ;;
            *) ;;
        esac
    fi

    read -rp "Pressione Enter para confirmar e continuar..." _

    rm -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true

    if install_letsencrypt; then
        echo -e "${GB}✅ Certificado Let's Encrypt pronto em ${CB}$SSL_DIR${RESET}"
        rm -f "$SSL_DIR/fullchain.pem.bak" "$SSL_DIR/privkey.pem.bak" 2>/dev/null || true
        _restore_xray_if_needed
        exit 0
    else
        echo ""
        echo -e "${BG_RED}  FALHA NA VALIDAÇÃO LET'S ENCRYPT  ${RESET}"
        echo -e "${YB}>>> Fallback automático: gerando autoassinado...${RESET}"
        make_selfsigned
        rm -f "$SSL_DIR/fullchain.pem.bak" "$SSL_DIR/privkey.pem.bak" 2>/dev/null || true
        _restore_xray_if_needed
        exit 0
    fi
    ;;

  2|*)
    rm -f "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" 2>/dev/null || true
    make_selfsigned
    rm -f "$SSL_DIR/fullchain.pem.bak" "$SSL_DIR/privkey.pem.bak" 2>/dev/null || true
    _restore_xray_if_needed
    exit 0
    ;;
esac
