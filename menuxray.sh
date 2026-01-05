#!/bin/bash
# menuxray.sh - Versão V7.3 (Backup Seguro + UUID na Lista)

# --- CONFIGURAÇÃO ---
XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"
XRAY_DIR="/opt/XrayTools"
ACTIVE_DOMAIN_FILE="$XRAY_DIR/active_domain"
USER_DB="$XRAY_DIR/users.db"

# CONFIGURAÇÃO DO LIMITADOR EXTERNO
LIMITER_LOCAL="/bin/limiterxray.sh"
LIMITER_URL="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/limiterxray.sh"

mkdir -p "$XRAY_DIR"
mkdir -p "$SSL_DIR"
touch "$USER_DB"

# Instala dependências silenciosamente se faltarem
if ! command -v jq &> /dev/null; then apt-get install jq -y > /dev/null 2>&1; fi
if ! command -v bc &> /dev/null; then apt-get install bc -y > /dev/null 2>&1; fi
if ! command -v uuidgen &> /dev/null; then apt-get install uuid-runtime -y > /dev/null 2>&1; fi

# --- CORES ---
TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_BLUE='\033[1;34m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

header_blue() {
    clear
    echo -e "${TITLE_BAR}   $1   ${RESET}"
    echo ""
}

header_red() {
    clear
    echo -e "\033[1;41;37m   $1   ${RESET}"
    echo ""
}

# --- SISTEMA ---
func_install_official_core() {
    header_blue "INSTALANDO XRAY CORE"
    echo "Aguarde..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
    if [ $? -eq 0 ]; then echo -e "${TXT_GREEN}✅ Sucesso!${RESET}"; sleep 1; else echo -e "${TXT_RED}❌ Falha.${RESET}"; sleep 2; fi
}

func_check_cert() {
    if [ ! -f "$KEY_FILE" ] || [ ! -f "$CRT_FILE" ]; then return 1; fi
    return 0
}

func_xray_cert() {
    local domain="$1"
    mkdir -p "$SSL_DIR"
    echo "Gerando Certificado para: $domain..."
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Dragon/OU=VPN/CN=$domain" \
        -keyout "$KEY_FILE" -out "$CRT_FILE" > /dev/null 2>&1
    chmod 777 "$SSL_DIR"; chmod 777 "$KEY_FILE"; chmod 644 "$CRT_FILE"
}

# --- MÓDULOS EXTERNOS ---
func_module_block() {
    curl -s -L -o /tmp/block_user.sh "https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/block_user.sh"
    chmod +x /tmp/block_user.sh
    bash /tmp/block_user.sh
    rm -f /tmp/block_user.sh
}

func_module_unblock() {
    curl -s -L -o /tmp/unblock_user.sh "https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/unblock_user.sh"
    chmod +x /tmp/unblock_user.sh
    bash /tmp/unblock_user.sh
    rm -f /tmp/unblock_user.sh
}

# --- FUNÇÃO DE BACKUP DO SISTEMA (SEGURO E OTIMIZADO) ---
func_backup_system() {
    clear
    header_blue "SISTEMA DE BACKUP"
    echo "Isso irá salvar:"
    echo " • Banco de Dados de Usuários (users.db)"
    echo " • Configurações do Xray (config.json)"
    echo " • Certificados e Chaves"
    echo ""
    
    echo -e "${TXT_CYAN}[1] CRIAR NOVO BACKUP (Substitui o anterior)${RESET}"
    echo -e "${TXT_CYAN}[0] VOLTAR${RESET}"
    echo ""
    read -rp "Opção: " bkp_opt

    if [[ "$bkp_opt" != "1" ]]; then return; fi

    local backup_dir="/root/backups"
    local date_now=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/backup_dragoncore_${date_now}.tar.gz"
    local filename=$(basename "$backup_file")
    
    mkdir -p "$backup_dir"

    echo ""
    echo "📦 Criando novo arquivo de backup..."
    
    # Verifica se os arquivos cruciais existem
    if [ ! -f "/opt/XrayTools/users.db" ] && [ ! -d "/usr/local/etc/xray" ]; then
        echo -e "${TXT_RED}❌ Erro: Arquivos do sistema não encontrados!${RESET}"
        read -rp "Pressione ENTER..."
        return
    fi

    # 1. Cria o backup NOVO primeiro (tentativa segura)
    tar -czPf "$backup_file" /opt/XrayTools /usr/local/etc/xray > /dev/null 2>&1

    # 2. Verifica se criou com sucesso antes de apagar os antigos
    if [ -f "$backup_file" ]; then
        echo ""
        echo "🧹 Limpando backups antigos..."
        # Remove todos os .tar.gz nesta pasta que NÃO sejam o arquivo que acabamos de criar
        find "$backup_dir" -name "*.tar.gz" -type f ! -name "$filename" -delete

        echo -e "${TXT_GREEN}✅ BACKUP CRIADO E ANTIGOS REMOVIDOS!${RESET}"
        echo -e "📂 Arquivo atual: ${TXT_CYAN}$filename${RESET}"
    else
        echo -e "${TXT_RED}❌ Falha ao criar backup. O anterior foi mantido (se existir).${RESET}"
    fi
    echo "========================================="
    read -rp "Pressione ENTER para voltar..."
}

# --- FUNÇÃO DE RESTAURAÇÃO DO SISTEMA (INTELIGENTE) ---
func_restore_system() {
    clear
    header_red "RESTAURAÇÃO DE SISTEMA"
    
    local backup_dir="/root/backups"

    # --- VERIFICAÇÃO SE EXISTE ARQUIVO ---
    # Verifica se a pasta existe E se tem pelo menos um arquivo .tar.gz dentro
    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir"/*.tar.gz 2>/dev/null)" ]; then
        echo -e "${TXT_YELLOW}⚠️  AVISO IMPORTANTE:${RESET}"
        echo "Não existe nenhum arquivo de backup na pasta:"
        echo -e "${TXT_CYAN}/root/backups/${RESET}"
        echo ""
        echo "O cliente nunca realizou um backup ou o arquivo foi excluído."
        echo ""
        read -rp "Pressione ENTER para retornar ao menu principal..."
        return
    fi

    # Se chegou aqui, existe backup.
    echo -e "${TXT_YELLOW}⚠️  ATENÇÃO:${RESET} Isso irá substituir o banco de dados"
    echo "e as configurações atuais pelos dados do backup."
    echo ""

    # Lista arquivos
    shopt -s nullglob
    local backups=("$backup_dir"/*.tar.gz)
    shopt -u nullglob
    local total_backups=${#backups[@]}

    local selected_file=""

    # --- LÓGICA INTELIGENTE ---
    if [ "$total_backups" -eq 1 ]; then
        # Se só tem 1 arquivo (cenário ideal), seleciona direto
        selected_file="${backups[0]}"
        echo -e "Backup encontrado: ${TXT_CYAN}$(basename "$selected_file")${RESET}"
        echo ""
        read -rp "Deseja restaurar este backup agora? [s/n]: " confirm_auto
        if [[ "$confirm_auto" != "s" ]]; then return; fi

    else
        # Se tiver mais de 1 (caso o usuário tenha colocado manualmente), mostra lista
        echo "📂 Backups encontrados:"
        local i=1
        for bkp in "${backups[@]}"; do
            echo -e "${TXT_CYAN}[$i]${RESET} $(basename "$bkp")"
            ((i++))
        done
        echo ""
        echo -e "${TXT_CYAN}[0]${RESET} Cancelar"
        echo ""
        read -rp "Escolha o número do arquivo: " choice
        
        if [ "$choice" == "0" ] || [ -z "$choice" ]; then return; fi
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then echo -e "${TXT_RED}❌ Opção inválida!${RESET}"; sleep 2; return; fi
        
        local index=$((choice - 1))
        selected_file="${backups[$index]}"
        
        if [ -z "$selected_file" ]; then echo -e "${TXT_RED}❌ Arquivo inválido!${RESET}"; sleep 2; return; fi
    fi

    # Executa a restauração
    echo ""
    echo "⏳ Restaurando..."
    systemctl stop xray
    systemctl stop botxray

    # Extrai sobrescrevendo arquivos na raiz /
    tar -xzPf "$selected_file" -C /

    if [ $? -eq 0 ]; then
        systemctl restart xray
        systemctl restart botxray
        echo -e "${TXT_GREEN}✅ RESTAURAÇÃO CONCLUÍDA!${RESET}"
        echo "Seus usuários e configurações foram recuperados."
    else
        echo -e "${TXT_RED}❌ Falha crítica ao extrair arquivos.${RESET}"
        systemctl start xray
        systemctl start botxray
    fi
    
    echo "========================================="
    read -rp "Pressione ENTER para voltar..."
}

# --- INSTALAÇÃO DO BOT TELEGRAM ---
func_install_bot() {
    header_blue "INSTALADOR DO BOT TELEGRAM"
    
    echo "Esta opção irá instalar o Python e configurar seu Bot."
    echo "Tenha em mãos o TOKEN do BotFather e seu ID numérico."
    echo ""
    read -rp "Deseja continuar? [s/n]: " continue_opt
    if [[ "$continue_opt" != "s" ]]; then return; fi

    echo ""
    echo -e "${TXT_YELLOW}Instalando Python e Dependências...${RESET}"
    
    apt-get update
    apt-get install python3 python3-pip -y
    
    rm -f /usr/lib/python3.*/EXTERNALLY-MANAGED
    
    echo "Instalando biblioteca python-telegram-bot..."
    pip3 install python-telegram-bot  

    echo -e "${TXT_GREEN}Dependências instaladas!${RESET}"
    echo ""
    
    # Coleta de Dados
    read -rp "Digite o TOKEN do Bot (BotFather): " bot_token
    read -rp "Digite o SEU ID (Admin ID): " admin_id

    if [ -z "$bot_token" ] || [ -z "$admin_id" ]; then
        echo -e "${TXT_RED}Dados inválidos!${RESET}"
        sleep 2
        return
    fi

    echo "Baixando código do bot do GitHub..."
    rm -f /opt/XrayTools/botxray.py
    
    curl -s -L -o /opt/XrayTools/botxray.py "https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main/botxray.py"
    
    if [ ! -f "/opt/XrayTools/botxray.py" ]; then
        echo -e "${TXT_RED}Erro ao baixar botxray.py! Verifique seu GitHub.${RESET}"
        sleep 3
        return
    fi

    sed -i "s/SEU_TOKEN_AQUI/$bot_token/g" /opt/XrayTools/botxray.py
    sed -i "s/123456789/$admin_id/g" /opt/XrayTools/botxray.py

    echo "Criando serviço do sistema..."
    cat <<EOF > /etc/systemd/system/botxray.service
[Unit]
Description=DragonCore Telegram Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/XrayTools
ExecStart=/usr/bin/python3 /opt/XrayTools/botxray.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable botxray
    systemctl restart botxray

    echo ""
    echo "========================================="
    echo -e "${TXT_GREEN}✅ BOT ATIVADO COM SUCESSO!${RESET}"
    echo "Vá no Telegram e mande /start para ele."
    echo "========================================="
    read -rp "Pressione ENTER para voltar..."
}

# --- GERAÇÃO DE CONFIG E LINK ---
func_generate_config() {
    local port="$1"
    local network="$2"
    local domain="$3"
    local api_port="$4"
    local use_tls="$5" 
    
    mkdir -p "$(dirname "$CONFIG_PATH")"
    local stream_settings=""
    
    # Policy para STATS
    local policy='{
        "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},
        "system": {"statsInboundUplink": true, "statsInboundDownlink": true}
    }'

    # Configura o Stream (Protocolo)
    if [ "$network" == "xhttp" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{network: "xhttp", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}], alpn: ["h2", "http/1.1"]}, xhttpSettings: {path: "/", scMaxBufferedPosts: 30}}')
        else
            stream_settings=$(jq -n '{network: "xhttp", security: "none", xhttpSettings: {path: "/", scMaxBufferedPosts: 30}}')
        fi
    elif [ "$network" == "ws" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{network: "ws", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}]}, wsSettings: {acceptProxyProtocol: false, path: "/"}}')
        else
            stream_settings=$(jq -n '{network: "ws", security: "none", wsSettings: {acceptProxyProtocol: false, path: "/"}}')
        fi
    elif [ "$network" == "grpc" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{network: "grpc", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}]}, grpcSettings: {serviceName: "gRPC"}}')
        else
            stream_settings=$(jq -n '{network: "grpc", security: "none", grpcSettings: {serviceName: "gRPC"}}')
        fi
    elif [ "$network" == "vision" ]; then
        stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{network: "tcp", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}], minVersion: "1.2", allowInsecure: true}, tcpSettings: {header: {type: "none"}}}')
    else 
        if [ "$use_tls" = "true" ]; then
             stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{network: "tcp", security: "tls", tlsSettings: {serverName: $dom, certificates: [{certificateFile: $crt, keyFile: $key}]}}')
        else
             stream_settings=$(jq -n '{network: "tcp", security: "none"}')
        fi
    fi

    jq -n --argjson stream "$stream_settings" --arg port "$port" --arg api "$api_port" --argjson pol "$policy" \
      '{log: {loglevel: "warning"}, stats: {}, api: {services: ["HandlerService", "LoggerService", "StatsService"], tag: "api"}, policy: $pol, inbounds: [{tag: "api", port: ($api | tonumber), protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, listen: "127.0.0.1"}, {tag: "inbound-dragoncore", port: ($port | tonumber), protocol: "vless", settings: {clients: [], decryption: "none", fallbacks: []}, streamSettings: $stream}], outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "blocked"}], routing: {domainStrategy: "AsIs", rules: [{type: "field", inboundTag: ["api"], outboundTag: "api"}]}}' > "$CONFIG_PATH"

    if [ "$network" == "vision" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow": "xtls-rprx-vision"}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    systemctl restart xray > /dev/null 2>&1
    sleep 2
    
    # --- RESUMO E LINK ---
    clear
    header_blue "INSTALAÇÃO CONCLUÍDA"
    
    if systemctl is-active --quiet xray; then
        echo -e "${TXT_GREEN}✅ Xray Ativo e Configurado!${RESET}"
    else
        echo -e "${TXT_RED}❌ Falha ao iniciar.${RESET}"
        journalctl -u xray -n 5 --no-pager
    fi

    local tls_msg="${TXT_RED}DESATIVADO (Porta Padrão)${RESET}"
    if [ "$use_tls" == "true" ]; then tls_msg="${TXT_GREEN}ATIVADO (TLS/SSL)${RESET}"; fi

    echo ""
    echo "========================================="
    echo -e " PROTOCOLO:      ${TXT_CYAN}${network^^}${RESET}"
    echo -e " DOMÍNIO (SNI):  ${TXT_CYAN}${domain}${RESET}"
    echo -e " PORTA PÚBLICA:  ${TXT_CYAN}${port}${RESET}"
    echo -e " PORTA INTERNA:  ${TXT_CYAN}${api_port}${RESET}"
    echo -e " CRIPTOGRAFIA:   ${tls_msg}"
    echo "========================================="
    echo ""

    local universal_uuid=$(uuidgen)
    local link=""
    local sec_param="none"
    if [ "$use_tls" == "true" ]; then sec_param="tls"; fi

    if [ "$network" == "grpc" ]; then
        link="vless://${universal_uuid}@${domain}:${port}?security=${sec_param}&encryption=none&type=grpc&serviceName=gRPC&sni=${domain}#VLESS_BASE"
    elif [ "$network" == "ws" ]; then
        link="vless://${universal_uuid}@${domain}:${port}?path=%2F&security=${sec_param}&encryption=none&host=${domain}&type=ws&sni=${domain}#VLESS_BASE"
    elif [ "$network" == "xhttp" ]; then
        if [ "$use_tls" == "true" ]; then
            link="vless://${universal_uuid}@${domain}:${port}?mode=auto&path=%2F&security=tls&encryption=none&host=${domain}&type=xhttp&sni=${domain}#VLESS_BASE"
        else
            link="vless://${universal_uuid}@${domain}:${port}?mode=auto&path=%2F&security=none&encryption=none&host=${domain}&type=xhttp#VLESS_BASE"
        fi
    elif [ "$network" == "vision" ]; then
        link="vless://${universal_uuid}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#VLESS_BASE"
    else
        link="vless://${universal_uuid}@${domain}:${port}?security=${sec_param}&encryption=none&type=tcp&sni=${domain}#VLESS_BASE"
    fi

    echo -e "${TXT_YELLOW}⚠️  LINK VLESS BASE (TEMPLATE) ⚠️${RESET}"
    echo "Copie e importe este link vless para o seu aplicativo vpn."
    echo ""
    echo -e "${TXT_BLUE}$link${RESET}"
    echo "========================================="
    read -rp "Pressione ENTER após salvar..."
}

func_add_user_logic() {
    local nick="$1"
    local expiry_days="$2"
    if [ -z "$nick" ]; then return 1; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "❌ Xray não configurado."; return 1; fi

    local uuid=$(uuidgen)
    local expiry=$(date -d "+$expiry_days days" +%F)

    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
        '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) += [{"id": $uuid, "email": $nick_arg, "level": 0}]' \
        "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    echo "$nick|$uuid|$expiry" >> "$USER_DB"
    systemctl restart xray > /dev/null 2>&1
    
    clear
    echo -e "${TXT_GREEN}✅ Usuário criado com sucesso!${RESET}"
    echo "-----------------------------------------"
    echo -e "👤 Usuário: ${TXT_CYAN}$nick${RESET}"
    echo -e "🔑 UUID:    ${TXT_YELLOW}$uuid${RESET}"
    echo -e "📅 Expira:  $expiry"
    echo "-----------------------------------------"
    echo "Copie o UUID acima e cole no seu Link Universal."
    echo "-----------------------------------------"
}

func_remove_user_logic() {
    local identifier="$1"
    if [ ! -f "$CONFIG_PATH" ]; then echo "❌ Erro config."; return; fi
    jq --arg id "$identifier" \
        '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(select(.id != $id and .email != $id))' \
        "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    if [ -f "$USER_DB" ]; then sed -i "/$identifier/d" "$USER_DB"; fi
    systemctl restart xray > /dev/null 2>&1
    echo -e "${TXT_GREEN}✅ Usuário removido.${RESET}"
    sleep 1
}

# --- PÁGINA: CRIAR USUÁRIO (COM VALIDAÇÃO 5-9 CARACTERES) ---
func_page_create_user() {
    header_blue "CRIAR USUÁRIO"
    echo "⚠️  Regras para o nome do usuário:"
    echo " • Mínimo 5 e Máximo 9 caracteres"
    echo " • Apenas letras e números (sem símbolos)"
    echo ""
    
    read -rp "Nome do usuário (0 p/ voltar): " raw_nick
    if [ "$raw_nick" == "0" ] || [ -z "$raw_nick" ]; then return; fi

    # --- VALIDAÇÃO RIGOROSA ---
    # Verifica se contém apenas letras/números E se tem entre 5 e 9 chars
    if ! [[ "$raw_nick" =~ ^[a-zA-Z0-9]{5,9}$ ]]; then
        echo ""
        echo -e "${TXT_RED}❌ ERRO: Formato inválido!${RESET}"
        echo "O usuário deve ter entre 5 e 9 caracteres."
        echo "Use apenas letras e números (sem espaços ou símbolos)."
        echo ""
        read -rp "Pressione ENTER para tentar novamente..."
        return
    fi
    # --------------------------

    if grep -q "$raw_nick" "$USER_DB"; then 
        echo -e "${TXT_RED}❌ Usuário já existe!${RESET}"
        sleep 2
        return
    fi
    
    read -rp "Dias de validade (Padrão 30): " days
    [ -z "$days" ] && days=30
    
    # Validação extra para dias (apenas números)
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then days=30; fi

    func_add_user_logic "$raw_nick" "$days"
    read -rp "Pressione ENTER para voltar ao menu..."
}

func_page_remove_user() {
    header_blue "REMOVER USUÁRIO"
    echo "Digite o Nome (nick) ou UUID para remover."
    read -rp "Identificador: " id_input
    if [ -n "$id_input" ]; then func_remove_user_logic "$id_input"; fi
}

func_page_list_users() {
    header_blue "LISTAR USUÁRIOS"
    # Ajustei o alinhamento para caber o UUID (36 chars)
    printf "%-15s | %-37s | %s\n" "USUÁRIO" "UUID" "VENCIMENTO"
    echo "-----------------------------------------------------------------------"
    
    if [ -f "$USER_DB" ]; then
        while IFS='|' read -r nick uuid expiry; do
            if [ -n "$nick" ]; then 
                printf "%-15s | %-37s | %s\n" "$nick" "$uuid" "$expiry"
            fi
        done < "$USER_DB"
    else
        echo "Nenhum usuário registrado."
    fi
    echo "-----------------------------------------------------------------------"
    echo ""; read -rp "Pressione ENTER para voltar..."
}

func_page_purge_expired() {
    header_blue "LIMPEZA DE EXPIRADOS"
    local today=$(date +%F)
    local count=0
    if [ -f "$USER_DB" ]; then
        touch "${USER_DB}.tmp"
        while IFS='|' read -r nick uuid expiry; do
            if [[ "$expiry" < "$today" ]]; then
                echo "Removendo: $nick ($expiry)"
                jq --arg id "$uuid" '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(select(.id != $id))' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
                ((count++))
            else
                echo "$nick|$uuid|$expiry" >> "${USER_DB}.tmp"
            fi
        done < "$USER_DB"
        mv "${USER_DB}.tmp" "$USER_DB"
        if [ $count -gt 0 ]; then systemctl restart xray > /dev/null 2>&1; echo "✅ $count usuários removidos."; else echo "✅ Nenhum usuário expirado."; fi
    fi
    echo ""; read -rp "Pressione ENTER para voltar..."
}

func_page_uninstall() {
    clear
    header_red "⚠️  DESINSTALAÇÃO COMPLETA ⚠️"
    echo -e "${TXT_RED}ATENÇÃO:${RESET} Esta ação é irreversível."
    echo "Isso irá remover:"
    echo " • O Xray Core e todas as configurações"
    echo " • O Bot do Telegram e o Banco de Dados (users.db)"
    echo " • Todos os usuários criados"
    echo " • Serviços do sistema (Systemd) e Logs"
    echo " • Todos os arquivos de Backup (/root/backups)"
    echo ""
    read -rp "Tem certeza que deseja continuar? [s/n]: " confirm
    
    if [[ "$confirm" != "s" ]]; then return; fi

    echo ""
    echo "1. Parando serviços..."
    systemctl stop xray > /dev/null 2>&1
    systemctl disable xray > /dev/null 2>&1
    systemctl stop botxray > /dev/null 2>&1
    systemctl disable botxray > /dev/null 2>&1

    echo "2. Removendo arquivos do sistema..."
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray@.service
    rm -f /etc/systemd/system/botxray.service
    systemctl daemon-reload

    rm -rf /usr/local/bin/xray
    rm -rf /usr/local/share/xray
    rm -rf /usr/local/etc/xray
    rm -rf /var/log/xray
    rm -rf /opt/XrayTools
    rm -rf /root/backups 

    echo "3. Limpando agendamentos (Cron)..."
    crontab -l | grep -v "menuxray" | grep -v "limiter" | crontab -
    
    echo "4. Removendo atalhos..."
    rm -f /usr/bin/xray-menu
    rm -f /usr/local/bin/uuidgen

    echo ""
    echo "========================================="
    echo -e "${TXT_GREEN}✅ DESINSTALAÇÃO CONCLUÍDA!${RESET}"
    echo "O sistema está completamente limpo."
    echo "========================================="
    echo ""
    
    exit 0
}

func_wizard_install() {
    header_blue "INSTALAÇÃO GUIADA (1/5)"
    read -rp "Deseja instalar/atualizar o Xray Core? [s/n]: " install_opt
    if [[ "$install_opt" =~ ^[Ss]$ ]]; then func_install_official_core; fi

    header_blue "CONFIGURAÇÃO (2/5)"
    echo "Deseja usar criptografia TLS/SSL (HTTPS)?"
    echo "1) SIM - (SUPREMO/AZION)"
    echo "2) NÃO - Conexão simples"
    read -rp "Opção [1/2]: " tls_opt
    local use_tls="false"
    if [ "$tls_opt" == "1" ]; then use_tls="true"; fi

    header_blue "CONFIGURAÇÃO (3/5)"
    read -rp "Digite a porta interna do Xray [Padrão 1080]: " api_port
    if [ -z "$api_port" ]; then api_port="1080"; fi

    header_blue "CONFIGURAÇÃO (4/5)"
    read -rp "Digite a porta de conexão pública (Ex: 443, 80): " pub_port
    if [ -z "$pub_port" ]; then pub_port="80"; fi

    header_blue "CONFIGURAÇÃO (5/5)"
    local domain_val=""
    if [ "$use_tls" == "true" ]; then
        echo -e "${TXT_CYAN}MODO SUPREMO ATIVADO!${RESET}"
        read -rp "Domínio (Ex: seudominio.azion.app): " domain_val
        func_xray_cert "$domain_val" 
    else
        echo "ℹ️  Modo sem TLS."
        read -rp "Domínio ou IP: " domain_val
        if [ -z "$domain_val" ]; then domain_val=$(curl -s icanhazip.com); fi
    fi
    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"

    header_blue "SELECIONE O PROTOCOLO"
    echo "1. ws (WebSocket)"
    echo "2. grpc (gRPC)"
    echo "3. xhttp (HTTP/2)"
    echo "4. tcp (Simples)"
    echo "5. vision (XTLS-Vision)"
    echo "0. Cancelar"
    echo ""
    read -rp "Digite o número da opção: " prot_opt
    local selected_net=""
    case "$prot_opt" in
        1) selected_net="ws" ;;
        2) selected_net="grpc" ;;
        3) selected_net="xhttp" ;;
        4) selected_net="tcp" ;;
        5) 
            selected_net="vision"
            if [ "$use_tls" == "false" ]; then
                read -rp "Domínio Fake (Vision): " domain_val
                func_xray_cert "$domain_val"; use_tls="true"; echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"
            fi ;;
        0) return ;;
        *) echo "❌ Inválido."; sleep 2; return ;;
    esac
    func_generate_config "$pub_port" "$selected_net" "$domain_val" "$api_port" "$use_tls"
}

# --- FUNÇÃO CHAMADA EXTERNA (DOWNLOADER + AUTO-REPAIR) ---
func_call_limiter() {
    echo "Verificando Módulo Limitador..."
    if [ -f "$CONFIG_PATH" ]; then
        if ! grep -q '"stats":' "$CONFIG_PATH"; then
            echo -e "${TXT_RED}⚠️ Correção detectada! Aplicando patch Stats...${RESET}"
            systemctl stop xray
            jq '.stats = {}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            systemctl restart xray
            echo "✅ Configuração corrigida automaticamente."
            sleep 2
        fi
    fi

    echo "Baixando atualização do GitHub..."
    curl -s -L -o "$LIMITER_LOCAL" "$LIMITER_URL"
    if [ $? -ne 0 ]; then
        echo -e "${TXT_RED}Erro ao baixar o módulo!${RESET}"
        sleep 2
        return
    fi
    chmod +x "$LIMITER_LOCAL"
    bash "$LIMITER_LOCAL"
}

# --- MENU PRINCIPAL ---
menu_display() {
    clear
    echo -e "${TITLE_BAR}         DRAGONCORE XRAY MANAGER         ${RESET}"
    echo ""
    local status_txt="${TXT_RED}DESATIVADO${RESET}"
    local proto_info="${TXT_RED}---${RESET}"
    local users_count="0"
    if [ -f "$USER_DB" ]; then users_count=$(wc -l < "$USER_DB"); fi

    if systemctl is-active --quiet xray; then
        status_txt="${TXT_GREEN}ATIVADO${RESET}"
        if [ -f "$CONFIG_PATH" ]; then
            local port=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").port' "$CONFIG_PATH" 2>/dev/null)
            local net=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.network' "$CONFIG_PATH" 2>/dev/null)
            [ -z "$port" ] && port="?"
            [ -z "$net" ] && net="?"
            proto_info="${TXT_BLUE}${net^^} (Porta: $port)${RESET}"
        fi
    fi

    echo "-----------------------------------------"
    echo -e " Estado:    $status_txt"
    echo -e " Clientes:  ${TXT_BLUE}$users_count${RESET}"
    echo -e " Info:      $proto_info"
    echo "-----------------------------------------"
    echo ""
    echo -e "${TXT_CYAN}[01]. CRIAR USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[02]. REMOVER USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[03]. LISTAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[04]. INSTALAR E CONFIGURAR XRAY (ASSISTENTE)${RESET}"
    echo -e "${TXT_CYAN}[05]. LIMPAR EXPIRADOS${RESET}"
    echo -e "${TXT_CYAN}[06]. DESINSTALAR (COMPLETO)${RESET}"
    echo -e "${TXT_CYAN}[07]. LIMITAR CONSUMO GIGAS (MÓDULO GITHUB)${RESET}"
    echo -e "${TXT_CYAN}[08]. ATIVAR BOT TELEGRAM${RESET}"
    echo -e "${TXT_CYAN}[09]. CRIAR BACKUP${RESET}"    
    echo -e "${TXT_CYAN}[10]. RESTAURAR BACKUP${RESET}" 
    echo -e "${TXT_CYAN}[11]. BLOQUEAR USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[12]. DESBLOQUEAR USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[00]. SAIR${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " choice
}

if [ -z "$1" ]; then
    while true; do
        menu_display
        case "$choice" in
            1) func_page_create_user ;;
            2) func_page_remove_user ;;
            3) func_page_list_users ;;
            4) func_wizard_install ;;
            5) func_page_purge_expired ;;
            6) func_page_uninstall ;; 
            7) func_call_limiter ;;
            8) func_install_bot ;;
            9) func_backup_system ;;    
            10) func_restore_system ;;
            11) func_module_block ;;
            12) func_module_unblock ;;
            0) exit 0 ;;
        esac
    done
else "$1" "${@:2}"; 
fi
