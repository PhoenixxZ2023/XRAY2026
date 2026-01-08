#!/bin/bash
# certxray.sh - Gerenciador de Certificados Externo

DOMAIN="$1"

# --- CORES ---
YB='\033[1;33m'   # Amarelo Negrito
RB='\033[1;31m'   # Vermelho Negrito
RESET='\033[0m'

# --- CAMINHOS ---
SSL_DIR="/opt/DragonCoreSSL"
LE_DIR="/etc/letsencrypt/live/$DOMAIN"
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"

if [ -z "$DOMAIN" ]; then
    echo -e "${RB}Erro: Nenhum domínio recebido pelo menu principal.${RESET}"
    read -rp "Digite o domínio manualmente: " DOMAIN
fi

mkdir -p "$SSL_DIR"

# Limpa a tela e mostra as opções
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
echo -e "${RB}     ⚠️  REQUER A PORTA 80 LIVRE${RESET}"
echo -e "${RB}     ✅  FUNCIONA EM ANDROID 13/14${RESET}"
echo ""
echo -e "${YB} [2] CERTIFICADO AUTO-ASSINADO (OPENSSL)${RESET}"
echo -e "${RB}     ⚠️  INSTALAÇÃO RÁPIDA (SEM VALIDAÇÃO)${RESET}"
echo -e "${RB}     ❌  PODE DAR ERRO DE 'INSEGURO'${RESET}"
echo ""
echo -e "${YB}====================================================${RESET}"
echo ""
read -rp "OPÇÃO: " cert_opt

# Limpa arquivos antigos para evitar conflito
rm -f "$SSL_DIR/fullchain.pem"
rm -f "$SSL_DIR/privkey.pem"

case $cert_opt in
    1)
        echo ""
        echo -e "${YB}>>> INICIANDO LET'S ENCRYPT...${RESET}"
        
        # Instala dependências (Snap/Certbot) se não tiver
        export DEBIAN_FRONTEND=noninteractive
        if ! command -v snap &> /dev/null; then apt-get update -y >/dev/null 2>&1 && apt-get install snapd -y >/dev/null 2>&1; fi
        if ! snap list | grep -q "certbot"; then
            snap install core >/dev/null 2>&1; snap refresh core >/dev/null 2>&1
            snap install --classic certbot >/dev/null 2>&1
            ln -sf /snap/bin/certbot /usr/bin/certbot
        fi

        # Libera porta 80
        systemctl stop xray >/dev/null 2>&1
        systemctl stop nginx >/dev/null 2>&1
        fuser -k 80/tcp >/dev/null 2>&1
        
        # Gera o certificado
        certbot certonly --standalone -d "$DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive

        # Verifica e Instala
        if [ -f "$LE_DIR/fullchain.pem" ]; then
            cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
            cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
            chmod 644 "$SSL_DIR/fullchain.pem"
            chmod 600 "$SSL_DIR/privkey.pem"
            
            # Cria renovador automático
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
            (crontab -l 2>/dev/null; echo "0 3 1 * * $RENEW_SCRIPT >/dev/null 2>&1") | crontab -
            
            echo -e "${YB}✅ SUCESSO! Certificado Oficial Instalado.${RESET}"
        else
            echo -e "${RB}❌ FALHA NO CERTBOT. USANDO AUTO-ASSINADO DE EMERGÊNCIA.${RESET}"
            openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
            -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
            chmod 644 "$SSL_DIR/fullchain.pem"
            chmod 600 "$SSL_DIR/privkey.pem"
        fi
        ;;
    
    2)
        echo ""
        echo -e "${YB}>>> GERANDO AUTO-ASSINADO...${RESET}"
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
        chmod 644 "$SSL_DIR/fullchain.pem"
        chmod 600 "$SSL_DIR/privkey.pem"
        echo -e "${YB}✅ CONCLUÍDO.${RESET}"
        ;;
        
    *)
        echo "Opção inválida. Usando Auto-assinado."
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
        ;;
esac
