#!/bin/bash
# certxray.sh - VERSÃO FINAL COM TODOS OS AVISOS E CORREÇÕES

DOMAIN="$1"
SSL_DIR="/opt/DragonCoreSSL"
LE_DIR="/etc/letsencrypt/live/$DOMAIN"
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"

# --- CORES ---
YB='\033[1;33m'   # Amarelo Negrito
RB='\033[1;31m'   # Vermelho Negrito
BG_RED='\033[41;1;37m' # Fundo Vermelho
RESET='\033[0m'

if [ -z "$DOMAIN" ]; then
    echo -e "${RB}Erro: Nenhum domínio recebido.${RESET}"
    read -rp "Digite o domínio manualmente: " DOMAIN
fi

# Prepara a pasta com permissões corretas
mkdir -p "$SSL_DIR"
chmod 777 "$SSL_DIR"

clear
echo -e "${YB}====================================================${RESET}"
echo -e "${YB}           GERENCIADOR DE CERTIFICADOS SSL          ${RESET}"
echo -e "${YB}====================================================${RESET}"
echo ""
echo -e "${YB}DOMÍNIO: $DOMAIN${RESET}"
echo ""
echo -e "${YB}ESCOLHA O TIPO DE CERTIFICADO:${RESET}"
echo ""
# --- AQUI ESTÁ O AVISO QUE VOCÊ PEDIU ---
echo -e "${YB} [1] CERTIFICADO OFICIAL LET'S ENCRYPT${RESET}"
echo -e "${RB}     ⚠️  REQ 1: PORTA 80 DEVE ESTAR LIVRE NA VPS${RESET}"
echo -e "${RB}     ⚠️  REQ 2: PORTA 80 DEVE ESTAR ABERTA NO FIREWALL${RESET}"
echo ""
echo -e "${YB} [2] CERTIFICADO AUTO-ASSINADO (LOCAL)${RESET}"
echo -e "${YB}     ✅  Não precisa de porta 80 / Instalação Rápida${RESET}"
echo ""
echo -e "${YB}====================================================${RESET}"
echo ""
read -rp "OPÇÃO: " cert_opt

rm -f "$SSL_DIR/fullchain.pem"
rm -f "$SSL_DIR/privkey.pem"

case $cert_opt in
    1)
        # Tela de Confirmação Crítica
        clear
        echo -e "${BG_RED}               ⚠️  LEIA COM ATENÇÃO  ⚠️               ${RESET}"
        echo ""
        echo -e "${YB}Você escolheu LET'S ENCRYPT. Para funcionar:${RESET}"
        echo ""
        echo -e "1. ${RB}PORTA 80 LIVRE:${RESET} Nenhum outro site ou script pode estar usando a porta 80."
        echo -e "   (O script tentará parar o Nginx/Apache automaticamente)."
        echo ""
        echo -e "2. ${RB}PORTA 80 ABERTA:${RESET} Se usa Oracle/AWS/Google, abra a porta 80 no site deles."
        echo ""
        read -rp "Pressione [ENTER] se você confirma os requisitos..." confirm_80

        echo -e "${YB}>>> PREPARANDO AMBIENTE...${RESET}"
        
        export DEBIAN_FRONTEND=noninteractive
        if ! command -v snap &> /dev/null; then apt-get update -y >/dev/null 2>&1 && apt-get install snapd -y >/dev/null 2>&1; fi
        if ! snap list | grep -q "certbot"; then
            snap install core >/dev/null 2>&1
            snap install --classic certbot >/dev/null 2>&1
            ln -sf /snap/bin/certbot /usr/bin/certbot
        fi

        # Tenta liberar a porta 80 na marra
        systemctl stop xray >/dev/null 2>&1
        systemctl stop nginx >/dev/null 2>&1
        fuser -k 80/tcp >/dev/null 2>&1
        sleep 2
        
        echo -e "${YB}>>> GERANDO CERTIFICADO...${RESET}"
        certbot certonly --standalone -d "$DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive

        if [ -f "$LE_DIR/fullchain.pem" ]; then
            cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
            cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
            
            # Ajusta permissões para o Xray ler
            chmod 755 "$SSL_DIR"
            chmod 644 "$SSL_DIR/fullchain.pem"
            chmod 644 "$SSL_DIR/privkey.pem"
            
            cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
systemctl stop xray
fuser -k 80/tcp
certbot renew --quiet
cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
chmod 777 "$SSL_DIR/fullchain.pem"
chmod 777 "$SSL_DIR/privkey.pem"
systemctl restart xray
EOF
            chmod +x "$RENEW_SCRIPT"
            (crontab -l 2>/dev/null; echo "0 3 1 * * $RENEW_SCRIPT >/dev/null 2>&1") | crontab -
            
            echo -e "${YB}✅ SUCESSO! Certificado Instalado.${RESET}"
        else
            echo ""
            echo -e "${BG_RED}  FALHA NA VALIDAÇÃO  ${RESET}"
            echo -e "${RB}Não foi possível gerar o certificado oficial.${RESET}"
            echo "Verifique: Porta 80 bloqueada ou Domínio incorreto."
            echo ""
            echo -e "${YB}>>> Instalando Auto-assinado de emergência...${RESET}"
            openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
            -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
            
            chmod 777 "$SSL_DIR/fullchain.pem"
            chmod 777 "$SSL_DIR/privkey.pem"
        fi
        ;;
    
    *)
        echo "Gerando Auto-assinado..."
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
        
        chmod 777 "$SSL_DIR/fullchain.pem"
        chmod 777 "$SSL_DIR/privkey.pem"
        ;;
esac
