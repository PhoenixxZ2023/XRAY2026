#!/bin/bash
# certxray.sh - Gerenciador de Certificados DragonCore (Pro Edition)
# Baseado na logica de renovacao segura e Snap

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

header_blue "GERANDO CERTIFICADO SSL (SNAP + RENOVAÇÃO)"

# 1. VERIFICA PORTA 80
echo "Verificando porta 80..."
if ! command -v lsof &> /dev/null; then apt-get install lsof -y > /dev/null 2>&1; fi
port80_pid=$(lsof -t -i:80)

if [ -n "$port80_pid" ]; then
    echo -e "${TXT_RED}❌ AVISO: A porta 80 está ocupada!${RESET}"
    echo "O Certbot precisa dela livre."
    read -rp "Parar serviço temporariamente? [s/n]: " stop_opt
    if [[ "$stop_opt" == "s" ]]; then
        kill -9 $port80_pid > /dev/null 2>&1
        systemctl stop nginx > /dev/null 2>&1
        systemctl stop apache2 > /dev/null 2>&1
        systemctl stop xray > /dev/null 2>&1
        sleep 2
    else
        echo "Cancelando Certbot. Usando OpenSSL..."
        certbot_failed=true
    fi
fi

# 2. INSTALAÇÃO VIA SNAP (A MELHOR PRÁTICA)
if [ "$certbot_failed" != "true" ]; then
    echo -e "${TXT_YELLOW}🔧 Verificando Certbot (Snap)...${RESET}"
    
    if ! command -v snap &> /dev/null; then
        apt-get update -qq
        apt-get install snapd -y > /dev/null 2>&1
    fi

    # Instala/Atualiza Certbot via Snap
    snap install core > /dev/null 2>&1
    snap refresh core > /dev/null 2>&1
    snap install --classic certbot > /dev/null 2>&1
    ln -sf /snap/bin/certbot /usr/bin/certbot

    # 3. GERA O CERTIFICADO
    echo -e "${TXT_GREEN}🟢 Gerando certificado para $DOMAIN...${RESET}"
    
    if certbot certonly --standalone -d "$DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive; then
        echo -e "${TXT_GREEN}✅ SUCESSO! Certificado Gerado.${RESET}"
        
        # 4. A ZONA SEGURA (COPIA OS ARQUIVOS)
        # O Xray vai ler daqui, onde as permissões são garantidas
        LE_DIR="/etc/letsencrypt/live/$DOMAIN"
        cp "$LE_DIR/fullchain.pem" "$CRT_FILE"
        cp "$LE_DIR/privkey.pem" "$KEY_FILE"
        chmod 644 "$CRT_FILE"
        chmod 600 "$KEY_FILE"
        
        # 5. CRIA O SCRIPT DE RENOVAÇÃO AUTOMÁTICA
        echo -e "${TXT_YELLOW}🕒 Criando script de renovação inteligente...${RESET}"
        cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
# Script de Renovacao Automatica DragonCore
DOMAIN="$DOMAIN"
SSL_DIR="$SSL_DIR"
LE_DIR="/etc/letsencrypt/live/\$DOMAIN"

# Para o Xray se ele estiver usando a porta 80 (Opcional, mas seguro)
systemctl stop xray

# Tenta renovar
certbot renew --quiet

# Copia os novos arquivos para a pasta do DragonCore
cp "\$LE_DIR/fullchain.pem" "\$SSL_DIR/fullchain.pem"
cp "\$LE_DIR/privkey.pem" "\$SSL_DIR/privkey.pem"

# Ajusta permissoes
chmod 644 "\$SSL_DIR/fullchain.pem"
chmod 600 "\$SSL_DIR/privkey.pem"

# Reinicia o Xray para aplicar
systemctl restart xray
EOF
        chmod +x "$RENEW_SCRIPT"

        # 6. AGENDA NO CRON (TODO DIA 1, ÀS 3 DA MANHÃ)
        if ! crontab -l 2>/dev/null | grep -q "renew_cert.sh"; then
            (crontab -l 2>/dev/null; echo "0 3 1 * * $RENEW_SCRIPT >/dev/null 2>&1") | crontab -
            echo -e "${TXT_GREEN}✔ Renovação automática agendada.${RESET}"
        fi
        
        exit 0
    else
        echo -e "${TXT_RED}❌ FALHA NO CERTBOT.${RESET}"
        echo "Caindo para OpenSSL..."
        certbot_failed=true
    fi
fi

# 7. FALLBACK OPENSSL (PLANO B)
if [ "$certbot_failed" == "true" ]; then
    echo -e "${TXT_YELLOW}⚠️  Gerando Certificado Autoassinado (OpenSSL)...${RESET}"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" > /dev/null 2>&1
    chmod 644 "$CRT_FILE"
    chmod 600 "$KEY_FILE"
    echo -e "${TXT_GREEN}✔ Certificado Autoassinado criado.${RESET}"
fi
