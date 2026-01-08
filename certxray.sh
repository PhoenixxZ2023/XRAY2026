#!/bin/bash
# certxray.sh - Correção para "Not Yet Due"
# Lógica: Tenta gerar, mas se já existir, instala do mesmo jeito.

DOMAIN="$1"

# --- CAMINHOS ---
SSL_DIR="/opt/DragonCoreSSL"
LE_DIR="/etc/letsencrypt/live/$DOMAIN"
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"

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

# 1. INSTALAÇÃO DO SNAP/CERTBOT (Se não tiver)
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

# 3. EXECUÇÃO DO CERTBOT
header_blue "OBTENDO CERTIFICADO SSL"
echo -e "Domínio: ${TXT_YELLOW}$DOMAIN${RESET}"

# Tenta obter o certificado (ou renovar, ou manter o atual)
certbot certonly --standalone \
    -d "$DOMAIN" \
    --register-unsafely-without-email \
    --agree-tos \
    --non-interactive

# 4. A CORREÇÃO MÁGICA (VERIFICAÇÃO DE ARQUIVO)
# Aqui mudamos a lógica: Não importa se o comando acima deu "not due",
# nós verificamos se o arquivo EXISTE na pasta do sistema.

if [ -f "$LE_DIR/fullchain.pem" ]; then
    echo ""
    echo -e "${TXT_GREEN}✅ Certificado Válido Encontrado!${RESET}"
    echo -e "${TXT_YELLOW}🔄 Instalando no DragonCore...${RESET}"
    
    # Copia FORÇADA (-f) para garantir que sobrescreva o antigo/falso
    cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
    cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
    
    # Ajusta permissões
    chmod 644 "$SSL_DIR/fullchain.pem"
    chmod 600 "$SSL_DIR/privkey.pem"
    
    echo -e "${TXT_GREEN}✔ Certificado Oficial Instalado com Sucesso.${RESET}"

    # Cria script de renovação automática
    cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
systemctl stop xray
certbot renew --quiet
cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
chmod 644 "$SSL_DIR/fullchain.pem"
chmod 600 "$SSL_DIR/privkey.pem"
systemctl restart xray
EOF
    chmod +x "$RENEW_SCRIPT"
    
    # Adiciona no Cron (Agendador)
    if ! crontab -l 2>/dev/null | grep -q "renew_cert.sh"; then
        (crontab -l 2>/dev/null; echo "0 3 1 * * $RENEW_SCRIPT >/dev/null 2>&1") | crontab -
    fi
    
    exit 0

else
    # 5. FALLBACK (Só entra aqui se realmente NÃO existir certificado nenhum)
    echo ""
    echo -e "${TXT_RED}❌ O Certbot não gerou os arquivos.${RESET}"
    echo "Verifique Firewall (Porta 80) ou apontamento de DNS."
    echo "Gerando certificado autoassinado de emergência..."
    
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" > /dev/null 2>&1
        
    chmod 644 "$SSL_DIR/fullchain.pem"
    chmod 600 "$SSL_DIR/privkey.pem"
fi
