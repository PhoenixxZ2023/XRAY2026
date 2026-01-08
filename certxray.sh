func_xray_cert() {
    local DOMAIN="$1"
    
    # --- CORES PERSONALIZADAS (BRILHANTE E NEGRITO) ---
    local YB='\033[1;33m'   # Amarelo Negrito Brilhante
    local RB='\033[1;31m'   # Vermelho Negrito
    local RESET='\033[0m'
    
    # --- CAMINHOS ---
    local SSL_DIR="/opt/DragonCoreSSL"
    local LE_DIR="/etc/letsencrypt/live/$DOMAIN"
    local RENEW_SCRIPT="$SSL_DIR/renew_cert.sh"
    
    mkdir -p "$SSL_DIR"
    
    clear
    echo -e "${YB}====================================================${RESET}"
    echo -e "${YB}           GERENCIADOR DE CERTIFICADOS SSL          ${RESET}"
    echo -e "${YB}====================================================${RESET}"
    echo ""
    echo -e "${YB}DOMÍNIO SELECIONADO: $DOMAIN${RESET}"
    echo ""
    echo -e "${YB}ESCOLHA O TIPO DE CERTIFICADO QUE DESEJA INSTALAR:${RESET}"
    echo ""
    echo -e "${YB} [1] CERTIFICADO OFICIAL LET'S ENCRYPT (RECOMENDADO)${RESET}"
    echo -e "${RB}     ⚠️  REQUER A PORTA 80 LIVRE E DOMÍNIO APONTADO${RESET}"
    echo -e "${RB}     ✅  FUNCIONA EM ANDROID 13/14 SEM ERROS${RESET}"
    echo ""
    echo -e "${YB} [2] CERTIFICADO AUTO-ASSINADO (OPENSSL)${RESET}"
    echo -e "${RB}     ⚠️  NÃO PRECISA DE PORTA 80${RESET}"
    echo -e "${RB}     ❌  PODE DAR ERRO DE 'INSEGURO' NO CLIENTE${RESET}"
    echo ""
    echo -e "${YB}====================================================${RESET}"
    echo ""
    read -rp "DIGITE A OPÇÃO (1 ou 2): " cert_opt

    # Limpa certificados antigos da pasta do Xray para evitar conflito
    rm -f "$SSL_DIR/fullchain.pem"
    rm -f "$SSL_DIR/privkey.pem"

    case $cert_opt in
        1)
            # --- OPÇÃO 1: LET'S ENCRYPT (OFICIAL) ---
            echo ""
            echo -e "${YB}>>> INICIANDO PROCESSO LET'S ENCRYPT...${RESET}"
            
            # Instalação do Snap/Certbot (Silenciosa)
            export DEBIAN_FRONTEND=noninteractive
            if ! command -v snap &> /dev/null; then apt-get update -y >/dev/null 2>&1 && apt-get install snapd -y >/dev/null 2>&1; fi
            if ! snap list | grep -q "certbot"; then
                snap install core >/dev/null 2>&1; snap refresh core >/dev/null 2>&1
                snap install --classic certbot >/dev/null 2>&1
                ln -sf /snap/bin/certbot /usr/bin/certbot
            fi

            echo -e "${YB}>>> LIBERANDO PORTA 80...${RESET}"
            systemctl stop xray >/dev/null 2>&1
            systemctl stop nginx >/dev/null 2>&1
            fuser -k 80/tcp >/dev/null 2>&1
            sleep 2

            echo -e "${YB}>>> SOLICITANDO CERTIFICADO...${RESET}"
            # Tenta gerar (com --force-renewal se necessário)
            certbot certonly --standalone -d "$DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive

            # VERIFICAÇÃO SE O ARQUIVO EXISTE (CORREÇÃO QUE FIZEMOS ANTES)
            if [ -f "$LE_DIR/fullchain.pem" ]; then
                echo -e "${YB}>>> CERTIFICADO ENCONTRADO! INSTALANDO...${RESET}"
                cp -f "$LE_DIR/fullchain.pem" "$SSL_DIR/fullchain.pem"
                cp -f "$LE_DIR/privkey.pem" "$SSL_DIR/privkey.pem"
                chmod 644 "$SSL_DIR/fullchain.pem"
                chmod 600 "$SSL_DIR/privkey.pem"

                # Script de Renovação
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
                
                echo ""
                echo -e "${YB}✅ SUCESSO! CERTIFICADO OFICIAL ATIVADO.${RESET}"
            else
                echo ""
                echo -e "${RB}❌ ERRO CRÍTICO: FALHA NO CERTBOT!${RESET}"
                echo -e "${RB}VERIFIQUE SE A PORTA 80 ESTÁ LIBERADA OU SE O IP ESTÁ CERTO.${RESET}"
                echo -e "${YB}>>> GERANDO AUTO-ASSINADO DE EMERGÊNCIA PARA NÃO FICAR OFFLINE...${RESET}"
                
                openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
                -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
                -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
                chmod 644 "$SSL_DIR/fullchain.pem"
                chmod 600 "$SSL_DIR/privkey.pem"
            fi
            ;;
        
        2)
            # --- OPÇÃO 2: OPENSSL (AUTO-ASSINADO) ---
            echo ""
            echo -e "${YB}>>> GERANDO CERTIFICADO AUTO-ASSINADO (LOCAL)...${RESET}"
            
            openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
            -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
            
            chmod 644 "$SSL_DIR/fullchain.pem"
            chmod 600 "$SSL_DIR/privkey.pem"
            
            echo ""
            echo -e "${YB}✅ SUCESSO! CERTIFICADO AUTO-ASSINADO INSTALADO.${RESET}"
            ;;
            
        *)
            echo -e "${RB}OPÇÃO INVÁLIDA! USANDO AUTO-ASSINADO POR PADRÃO.${RESET}"
            openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$DOMAIN" \
            -keyout "$SSL_DIR/privkey.pem" -out "$SSL_DIR/fullchain.pem" >/dev/null 2>&1
            chmod 644 "$SSL_DIR/fullchain.pem"
            chmod 600 "$SSL_DIR/privkey.pem"
            ;;
    esac

    # Reinicia o serviço no final
    systemctl restart xray
    sleep 2
}
