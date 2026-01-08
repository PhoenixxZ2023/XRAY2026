#!/bin/bash
# certxray.sh - Gerenciador de Certificados DragonCore (Versão Final Automática)
# Inclui instalação via Snap e Automação total sem perguntas

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

# --- VALIDAÇÃO ---
if [ -z "$DOMAIN" ]; then
    echo -e "${TXT_RED}Erro: Nenhum domínio informado.${RESET}"
    exit 1
fi

mkdir -p "$SSL_DIR"

header_blue "PREPARANDO AMBIENTE CERTBOT"

# 1. INSTALAÇÃO AUTOMÁTICA DO SNAP E CERTBOT (O que fizemos manualmente)
echo -e "${TXT_YELLOW}🔧 Verificando/Instalando Certbot via Snap...${RESET}"

# Atualiza pacotes básicos
export DEBIAN_FRONTEND=noninteractive
apt-get update -y > /dev/null 2>&1
apt-get install lsof -y > /dev/null 2>&1

# Instala Snap se não tiver
if ! command -v snap &> /dev/null; then
    echo "Instalando Snapd..."
    apt-get install snapd -y > /dev/null 2>&1
fi

# Instala Core e Certbot (Comandos manuais automatizados)
if ! snap list | grep -q "certbot"; then
    echo "Configurando Snap Core..."
    snap install core > /dev/null 2>&1
    snap refresh core > /dev/null 2>&1
    
    echo "Baixando Certbot Oficial..."
    snap install --classic certbot > /dev/null 2>&1
    ln -sf /snap/bin/certbot /usr/bin/certbot
else
    echo -e "${TXT_GREEN}✔ Certbot já instalado via Snap.${RESET}"
fi

# 2. LIMPEZA BRUTAL DA PORTA 80 (Para garantir que nada atrapalhe)
echo -e "${TXT_YELLOW}🧹 Liberando a porta 80...${RESET}"
systemctl stop xray > /dev/null 2>&1
systemctl stop nginx > /dev/null 2>&1
systemctl stop apache2 > /dev/null 2>&1

# Mata qualquer processo teimoso na porta 80
fuser -k 80/tcp > /dev/null 2>&1
sleep 2

# 3. GERAÇÃO DO CERTIFICADO (SEM PERGUNTAS Y/N)
header_blue "GERANDO CERTIFICADO SSL (LETS ENCRYPT)"
echo -e "Domínio: ${TXT_YELLOW}$DOMAIN${RESET}"
echo ""

# AQUI ESTÁ O SEGREDO: Flags para não perguntar nada ao cliente
if certbot certonly --standalone \
    -d "$DOMAIN" \
    --register-unsafely-without-email \
    --agree-tos \
    --non-interactive \
    --force-renewal; then

    echo ""
    echo -e "${TXT_GREEN}✅ SUCESSO! Certificado Gerado.${RESET}"
    
    # 4. CÓPIA DOS ARQUIVOS (O que você fez com cp)
    LE_DIR="/etc/letsencrypt/live/$DOMAIN"
    
    # Verifica se o arquivo existe antes de copiar
    if [ -f "$LE_DIR/fullchain.pem" ]; then
        cp "$LE_DIR/fullchain.pem" "$CRT_FILE"
        cp "$LE_DIR/privkey.pem" "$KEY_FILE"
        chmod 777 "$CRT_FILE"
        chmod 777 "$KEY_FILE"
        echo -e "${TXT_GREEN}✔ Arquivos copiados para DragonCoreSSL.${RESET}"
    else
        # Se por algum motivo o certbot disse OK mas não criou a pasta (raro)
        echo -e "${TXT_RED}Erro: Arquivos não encontrados em $LE_DIR${RESET}"
        exit 1
    fi

    # 5. CRIA O SCRIPT DE RENOVAÇÃO
    cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
systemctl stop xray
certbot renew --quiet
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/fullchain.pem"
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/privkey.pem"
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
    # 6. FALLBACK (Se der erro mesmo com tudo isso)
    echo ""
    echo -e "${TXT_RED}❌ FALHA NO CERTBOT.${RESET}"
    echo "Motivo provável: Bloqueio de Firewall ou IP incorreto."
    echo "Gerando certificado autoassinado para não ficar offline..."
    
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" > /dev/null 2>&1
        
    chmod 644 "$CRT_FILE"
    chmod 600 "$KEY_FILE"
    echo -e "${TXT_YELLOW}⚠️  Usando Certificado Autoassinado (OpenSSL).${RESET}"
fi
