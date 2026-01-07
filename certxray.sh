#!/bin/bash
# certxray.sh - Gerenciador de Certificados DragonCore
# Autor: Seu Nome / DragonCore

# --- RECEBE O DOMÍNIO COMO ARGUMENTO ---
DOMAIN="$1"

# --- CONFIGURAÇÕES E CORES (Necessário repetir aqui para funcionar sozinho) ---
SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

header_blue() {
    clear
    echo -e "${TITLE_BAR}   $1   ${RESET}"
    echo ""
}

# --- VALIDAÇÃO BÁSICA ---
if [ -z "$DOMAIN" ]; then
    echo -e "${TXT_RED}Erro: Nenhum domínio informado.${RESET}"
    echo "Uso: bash certxray.sh seudominio.com"
    exit 1
fi

# Instala dependências se faltar
if ! command -v lsof &> /dev/null; then apt-get install lsof -y > /dev/null 2>&1; fi
if ! command -v socat &> /dev/null; then apt-get install socat -y > /dev/null 2>&1; fi

mkdir -p "$SSL_DIR"

# --- INÍCIO DA LÓGICA ---
header_blue "GERANDO CERTIFICADO SSL (LETS ENCRYPT)"

# 1. AVISO E VERIFICAÇÃO DE PORTA 80
echo -e "${TXT_YELLOW}⚠️  REQUISITOS PARA O CERTIFICADO:${RESET}"
echo "1. O domínio $DOMAIN deve apontar para este IP."
echo "2. A porta 80 precisa estar LIVRE e ABERTA."
echo ""
echo "Verificando porta 80..."
sleep 1

port80_pid=$(lsof -t -i:80)

if [ -n "$port80_pid" ]; then
    echo -e "${TXT_RED}❌ AVISO: A porta 80 está ocupada!${RESET}"
    process_name=$(ps -p $port80_pid -o comm=)
    echo "Processo ocupando: $process_name (PID: $port80_pid)"
    echo ""
    echo "O Certbot PRECISA da porta 80 livre."
    read -rp "Parar serviço temporariamente? [s/n]: " stop_opt
    
    if [[ "$stop_opt" == "s" ]]; then
        echo "Parando processos..."
        kill -9 $port80_pid > /dev/null 2>&1
        systemctl stop nginx > /dev/null 2>&1
        systemctl stop apache2 > /dev/null 2>&1
        systemctl stop xray > /dev/null 2>&1 
        sleep 2
    else
        echo "Cancelando Certbot. Usando método manual..."
        certbot_failed=true
    fi
else
    echo -e "${TXT_GREEN}✅ Porta 80 está livre.${RESET}"
fi

# 2. TENTATIVA CERTBOT
certbot_failed=false

if [ "$certbot_failed" == "false" ]; then
    echo -e "${TXT_YELLOW}Tentando gerar certificado via Certbot...${RESET}"
    
    if ! command -v certbot >/dev/null 2>&1; then
        apt-get update -y > /dev/null 2>&1; apt-get install certbot -y > /dev/null 2>&1
    fi

    if certbot certonly --standalone -d "$DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive; then
        echo ""
        echo -e "${TXT_GREEN}✅ SUCESSO! Certificado Válido Gerado.${RESET}"
        
        cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CRT_FILE"
        cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$KEY_FILE"
        
        # Cria renovação automática
        if ! crontab -l | grep -q "certbot renew"; then
            (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --pre-hook 'systemctl stop xray' --post-hook 'systemctl restart xray'") | crontab -
        fi
        exit 0
    else
        echo -e "${TXT_RED}❌ FALHA NO CERTBOT.${RESET}"
        certbot_failed=true
    fi
fi

# 3. TENTATIVA OPENSSL (PLANO B)
if [ "$certbot_failed" == "true" ]; then
    echo ""
    echo -e "${TXT_YELLOW}⚠️  Gerando Certificado Autoassinado (OpenSSL)...${RESET}"
    
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" > /dev/null 2>&1
        
    echo -e "${TXT_GREEN}✔ Certificado Autoassinado criado.${RESET}"
fi

chmod 777 "$CRT_FILE"
chmod 777 "$KEY_FILE"
