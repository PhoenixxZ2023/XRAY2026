#!/bin/bash
# certxray.sh - VERSÃO FINAL SEGURA V7.5 (Híbrida)
# Mantém seu menu original + Aplica a correção de permissão 'nobody' que funcionou.

# --- CORREÇÃO DO ERRO DE INPUT ---
RAW_INPUT="$*"
DOMAIN=$(echo "$RAW_INPUT" | awk '{print $NF}')

SSL_DIR="/opt/DragonCoreSSL"
RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"
LE_DIR=""

# --- CORES ---
YB='\033[1;33m'   
RB='\033[1;31m'   
BG_RED='\033[41;1;37m' 
RESET='\033[0m'

# --- NOVA FUNÇÃO DE PERMISSÕES (Baseada no que funcionou para você) ---
apply_cert_permissions() {
    echo "Aplicando permissões blindadas..."
    
    # Tenta definir o dono como 'nobody' (Padrão do Xray)
    if id "nobody" &>/dev/null; then
        chown -R nobody:nogroup "$SSL_DIR"
    elif id "xray" &>/dev/null; then
        chown -R xray:xray "$SSL_DIR"
    else
        # Fallback para root se não achar ninguém, mas mantém chmod restrito
        chown -R root:root "$SSL_DIR"
    fi
    
    # Permissões de Pasta (Acesso de leitura/execução para dono e grupo)
    chmod 777 "$SSL_DIR"

    # Arquivos: Fullchain legível por todos, Privkey apenas pelo dono
    if [ -f "$SSL_DIR/fullchain.pem" ]; then
        chmod 777 "$SSL_DIR/fullchain.pem"
    fi

    if [ -f "$SSL_DIR/privkey.pem" ]; then
        chmod 777 "$SSL_DIR/privkey.pem"
    fi
}

if [ -z "$DOMAIN" ]; then
    echo -e "${RB}Erro: Nenhum domínio recebido.${RESET}"
    read -rp "Digite o domínio manualmente: " DOMAIN
fi

LE_DIR="/etc/letsencrypt/live/$DOMAIN"

# Prepara a pasta 
mkdir -p "$SSL_DIR"

clear
echo -e "${YB}====================================================${RESET}"
echo -e "${YB}            GERENCIADOR DE CERTIFICADOS SSL          ${RESET}"
echo -e "${YB}====================================================${RESET}"
echo -e "${YB}DOMÍNIO: $DOMAIN${RESET}"
echo ""
echo -e "${YB}ESCOLHA O TIPO DE CERTIFICADO:${RESET}"
echo ""
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
        # Tela de Confirmação
        clear
        echo -e "${BG_RED}                ⚠️  LEIA COM ATENÇÃO  ⚠️                ${RESET}"
        echo ""
        echo -e "${YB}Você escolheu LET'S ENCRYPT. Para funcionar:${RESET}"
        echo -e "1. ${RB}PORTA 80 LIVRE:${RESET} O script vai parar o Nginx/Apache."
        echo -e "2. ${RB}PORTA 80 ABERTA:${RESET} Libere no Firewall da VPS."
        echo ""
        read -rp "Pressione [ENTER] para confirmar..." confirm_80

        echo -e "${YB}>>> PREPARANDO AMBIENTE...${RESET}"
        
        export DEBIAN_FRONTEND=noninteractive
        # Instalação simplificada do Certbot se não tiver
        if ! command -v certbot &> /dev/null; then 
            apt-get update -y >/dev/null 2>&1
            apt-get install certbot -y >/dev/null 2>&1
        fi

        # Libera porta 80
        systemctl stop xray >/dev/null 2>&1
        systemctl stop nginx >/dev/null 2>&1
        if command -v fuser >/dev/null; then fuser -k 80/tcp >/dev/null 2>&1; fi
        sleep 2
        
        echo -e "${YB}>>> GERANDO CERTIFICADO...${RESET}"
        certbot certonly --standalone -d "$DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive

        if [ -f "$LE_DIR/fullchain.pem" ]; then
            cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
            cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
            
            # APLICA A CORREÇÃO QUE FUNCIONOU
            apply_cert_permissions
            
            # Cria script de renovação JÁ COM A CORREÇÃO para o futuro
            cat > "$RENEW_SCRIPT" <<EOF
#!/bin/bash
SSL_DIR="/opt/DragonCoreSSL"
LE_DIR="/etc/letsencrypt/live/$DOMAIN"

systemctl stop xray
if command -v fuser >/dev/null; then fuser -k 80/tcp; fi

certbot renew --quiet --force-renewal

cp -f "\$LE_DIR/fullchain.pem" "\$SSL_DIR/fullchain.pem"
cp -f "\$LE_DIR/privkey.pem" "\$SSL_DIR/privkey.pem"

# REAPLICA AS PERMISSÕES CORRETAS
chown -R nobody:nogroup "\$SSL_DIR"
chmod 777 "\$SSL_DIR"
chmod 777 "\$SSL_DIR/fullchain.pem"
chmod 777 "\$SSL_DIR/privkey.pem"

systemctl restart xray
EOF
            chmod +x "$RENEW_SCRIPT"
            
            # Cronjob
            (crontab -l 2>/dev/null | grep -v "$RENEW_SCRIPT"; echo "0 3 * * * $RENEW_SCRIPT >/dev/null 2>&1") | crontab -
            
            echo -e "${YB}✅ SUCESSO! Certificado Instalado.${RESET}"
        else
            echo ""
            echo -e "${BG_RED}  FALHA NA VALIDAÇÃO  ${RESET}"
            echo -e "Instalando Auto-assinado de emergência..."
            
            openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
            -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
            
            apply_cert_permissions
        fi
        ;;
    
    *)
        echo "Gerando Auto-assinado..."
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
        -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
        
        apply_cert_permissions
        ;;
esac
