#!/bin/bash
# certxray.sh - Gerenciador de Certificados DragonCore (Versão Final Automática)

DOMAIN="$1"

# --- CAMINHOS ---
SSL_DIR="/opt/DragonCoreSSL"
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"

# --- CORES ---
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

header_blue() {
    clear
    echo -e "${TITLE_BAR}   $1   ${RESET}"
    echo ""
}

if [ -z "$DOMAIN" ]; then
    echo -e "${TXT_RED}Erro: Nenhum domínio informado.${RESET}"
    exit 1
fi

mkdir -p "$SSL_DIR"

header_blue "PREPARANDO AMBIENTE CERTBOT"

# 1. INSTALAÇÃO AUTOMÁTICA (SNAP)
export DEBIAN_FRONTEND=noninteractive
if ! command -v snap &> /dev/null; then
    apt-get update -y > /dev/null 2>&1
    apt-get install snapd -y > /dev/null 2>&1
fi

if ! snap list | grep -q "certbot"; then
    snap install core > /dev/null 2>&1
    snap refresh core > /dev/null 2>&1
    snap install --classic certbot > /dev/null 2>&1
    ln -sf /snap/bin/certbot /usr/bin/certbot
fi

# 2. LIMPEZA DA PORTA 80
echo -e "${TXT_YELLOW}🧹 Liberando a porta 80...${RESET}"
systemctl stop xray > /dev/null 2>&1
systemctl stop nginx > /dev/null 2>&1
fuser -k 80/tcp > /dev/null 2>&1
sleep 2

# 3. GERAÇÃO DO CERTIFICADO (COM FORÇA BRUTA)
header_blue "GERANDO CERTIFICADO SSL"
echo -e "Domínio: ${TXT_YELLOW}$DOMAIN${RESET}"

# AQUI ESTÁ A CORREÇÃO: --force-renewal
# Isso obriga a gerar um novo, evitando o erro "not yet due"
if certbot certonly --standalone \
    -d "$DOMAIN" \
    --register-unsafely-without-email \
    --agree-tos \
    --non-interactive \
    --force-renewal; then

    echo ""
    echo -e "${TXT_GREEN}✅ SUCESSO! Certificado Gerado.${RESET}"
    
    # 4. CÓPIA OBRIGATÓRIA
    LE_DIR="/etc/letsencrypt/live/$DOMAIN"
    
    if [ -f "$LE_DIR/fullchain.pem" ]; then
        cp -f "$LE_DIR/fullchain.pem" "$CRT_FILE"
        cp -f "$LE_DIR/privkey.pem" "$KEY_FILE"
        chmod 644 "$CRT_FILE"
        chmod 600 "$KEY_FILE"
        echo -e "${TXT_GREEN}✔ Certificado instalado no DragonCore.${RESET}"
    else
        echo -e "${TXT_RED}Erro crítico: Arquivos não encontrados!${RESET}"
        exit 1
    fi

    # 5. SCRIPT DE RENOVAÇÃO
    cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
systemctl stop xray
certbot renew --quiet --force-renewal
cp -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/fullchain.pem"
cp -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/privkey.pem"
chmod 644 "$SSL_DIR/fullchain.pem"
chmod 600 "$SSL_DIR/privkey.pem"
systemctl restart xray
EOF
    chmod +x "$RENEW_SCRIPT"

    # Cronjob
    if ! crontab -l 2>/dev/null | grep -q "renew_cert.sh"; then
        (crontab -l 2>/dev/null; echo "0 3 1 * * $RENEW_SCRIPT >/dev/null 2>&1") | crontab -
    fi
    
    exit 0

else
    # 6. FALLBACK OPENSSL
    echo ""
    echo -e "${TXT_RED}❌ FALHA NO CERTBOT.${RESET}"
    echo "Gerando Autoassinado..."
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" > /dev/null 2>&1
    chmod 644 "$CRT_FILE"
    chmod 600 "$KEY_FILE"
fi
