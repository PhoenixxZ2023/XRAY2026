#!/bin/bash
# certxray.sh - COM CORREÇÃO DE PERMISSÃO PARA LET'S ENCRYPT

DOMAIN="$1"
SSL_DIR="/opt/DragonCoreSSL"
LE_DIR="/etc/letsencrypt/live/$DOMAIN"
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"

# --- CORES ---
YB='\033[1;33m'   # Amarelo
RB='\033[1;31m'   # Vermelho
RESET='\033[0m'

if [ -z "$DOMAIN" ]; then
    echo -e "${RB}Erro: Nenhum domínio recebido.${RESET}"
    read -rp "Digite o domínio manualmente: " DOMAIN
fi

# 1. GARANTIA TOTAL: Cria a pasta e já libera a entrada (755)
mkdir -p "$SSL_DIR"
chmod 755 "$SSL_DIR"

clear
echo -e "${YB}====================================================${RESET}"
echo -e "${YB}           GERENCIADOR DE CERTIFICADOS SSL          ${RESET}"
echo -e "${YB}====================================================${RESET}"
echo ""
echo -e "${YB}DOMÍNIO: $DOMAIN${RESET}"
echo ""
echo -e "${YB}ESCOLHA O TIPO DE CERTIFICADO:${RESET}"
echo ""
echo -e "${YB} [1] CERTIFICADO OFICIAL LET'S ENCRYPT (RECOMENDADO)${RESET}"
echo -e "${YB} [2] CERTIFICADO AUTO-ASSINADO (LOCAL)${RESET}"
echo ""
read -rp "OPÇÃO: " cert_opt

# Limpa o local antes de começar
rm -f "$SSL_DIR/fullchain.pem"
rm -f "$SSL_DIR/privkey.pem"

case $cert_opt in
    1)
        echo -e "${YB}>>> INICIANDO LET'S ENCRYPT...${RESET}"
        
        # Instala dependências
        export DEBIAN_FRONTEND=noninteractive
        if ! command -v snap &> /dev/null; then apt-get update -y >/dev/null 2>&1 && apt-get install snapd -y >/dev/null 2>&1; fi
        if ! snap list | grep -q "certbot"; then
            snap install core >/dev/null 2>&1
            snap install --classic certbot >/dev/null 2>&1
            ln -sf /snap/bin/certbot /usr/bin/certbot
        fi

        # Libera porta 80
        systemctl stop xray >/dev/null 2>&1
        systemctl stop nginx >/dev/null 2>&1
        fuser -k 80/tcp >/dev/null 2>&1
        
        # Gera o certificado
        certbot certonly --standalone -d "$DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive

        if [ -f "$LE_DIR/fullchain.pem" ]; then
            # Copia os arquivos
            cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
            cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
            
            # --- A CORREÇÃO MÁGICA ---
            # Força a pasta ser acessível e os arquivos serem legíveis
            echo "Ajustando permissões para o Xray..."
            chmod 755 "$SSL_DIR"
            chmod 644 "$SSL_DIR/fullchain.pem"
            chmod 644 "$SSL_DIR/privkey.pem"
            # -------------------------
            
            # Cria script de renovação
            cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
systemctl stop xray
certbot renew --quiet
cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
chmod 644 "$SSL_DIR/fullchain.pem"
chmod 644 "$SSL_DIR/privkey.pem"
systemctl restart xray
EOF
            chmod +x "$RENEW_SCRIPT"
            (crontab -l 2>/dev/null; echo "0 3 1 * * $RENEW_SCRIPT >/dev/null 2>&1") | crontab -
            
            echo -e "${YB}✅ SUCESSO! Certificado Instalado.${RESET}"
        else
            echo -e "${RB}❌ FALHA NO CERTBOT. USANDO AUTO-ASSINADO DE EMERGÊNCIA.${RESET}"
            openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
            -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
            
            chmod 644 "$SSL_DIR/fullchain.pem"
            chmod 644 "$SSL_DIR/privkey.pem"
        fi
        ;;
    
    *)
        echo "Gerando Auto-assinado..."
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
        
        # Garante permissão no autoassinado também
        chmod 644 "$SSL_DIR/fullchain.pem"
        chmod 644 "$SSL_DIR/privkey.pem"
        ;;
esac
