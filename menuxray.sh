#!/bin/bash
# menuxray.sh - Versao V7.3 Visual Premium (Vertical)
# CORREÇÕES: Segurança Token Bot (sed), Permissões SSL (chmod 600), Cache de Scripts e UX

# --- CONFIGURACAO ---
XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"
XRAY_DIR="/opt/XrayTools"
ACTIVE_DOMAIN_FILE="$XRAY_DIR/active_domain"
USER_DB="$XRAY_DIR/users.db"

# CAMINHOS LOCAIS PARA CACHE (Evita baixar toda hora)
LIMITER_LOCAL="/usr/local/bin/limiterxray.sh"
MONITOR_LOCAL="/usr/local/bin/onlinexray.sh"
BLOCK_LOCAL="/usr/local/bin/block_user.sh"
UNBLOCK_LOCAL="/usr/local/bin/unblock_user.sh"
CERT_LOCAL="/usr/local/bin/certxray.sh"
BOT_SHELL_LOCAL="/usr/local/bin/botxray.sh"

# URLS GITHUB
REPO_BASE="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main"

mkdir -p "$XRAY_DIR"
mkdir -p "$SSL_DIR"
touch "$USER_DB"

# Instala dependencias essenciais
if ! command -v jq &> /dev/null; then apt-get install jq -y > /dev/null 2>&1; fi
if ! command -v bc &> /dev/null; then apt-get install bc -y > /dev/null 2>&1; fi
if ! command -v uuidgen &> /dev/null; then apt-get install uuid-runtime -y > /dev/null 2>&1; fi
if ! command -v lsof &> /dev/null; then apt-get install lsof -y > /dev/null 2>&1; fi
if ! command -v ss &> /dev/null; then apt-get install iproute2 -y > /dev/null 2>&1; fi


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

# --- FUNÇÃO AUXILIAR DE DOWNLOAD (CACHE) ---
func_download_exec() {
    local file_path="$1"
    local url="$2"
    local description="$3"

    # Só baixa se não existir ou se estiver vazio
    if [ ! -s "$file_path" ]; then
        echo -e "${TXT_YELLOW}Baixando módulo: $description...${RESET}"
        curl -s -L -o "$file_path" "$url"
        chmod +x "$file_path"
        
        if [ ! -s "$file_path" ]; then
            echo -e "${TXT_RED}Erro ao baixar $description! Verifique conexão/GitHub.${RESET}"
            sleep 2
            return 1
        fi
    fi
    
    # Executa passando argumentos extras se houver
    bash "$file_path" "${@:4}"
}

# --- SISTEMA ---

# Instalacao Robusta do Xray
func_install_official_core() {
    header_blue "INSTALANDO XRAY CORE"
    
    # --- VERIFICAÇÃO INTELIGENTE DE DEPENDÊNCIAS ---
    if command -v unzip > /dev/null 2>&1 && command -v curl > /dev/null 2>&1 && command -v socat > /dev/null 2>&1; then
        echo -e "1. Dependências encontradas: ${TXT_GREEN}OK${RESET}"
    else
        echo "1. Instalando dependencias (unzip, curl, socat)..."
        apt-get update -y > /dev/null 2>&1
        apt-get install unzip curl socat -y > /dev/null 2>&1
    fi

    echo "2. Baixando instalador oficial..."
    rm -f /tmp/install_xray.sh
    
    curl -L -o /tmp/install_xray.sh "https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    
    if [ ! -f "/tmp/install_xray.sh" ]; then
        echo -e "${TXT_RED}Erro: Nao foi possivel baixar o instalador.${RESET}"
        sleep 3
        return
    fi

    echo "3. Executando instalacao..."
    chmod +x /tmp/install_xray.sh
    bash /tmp/install_xray.sh install
    
    local ret_val=$?
    rm -f /tmp/install_xray.sh

    echo "------------------------------------------------"
    if [ $ret_val -eq 0 ] && [ -f "/usr/local/bin/xray" ]; then
        echo -e "${TXT_GREEN}SUCESSO! Xray Core Instalado.${RESET}"
        sleep 2
    else
        echo -e "${TXT_RED}FALHA NA INSTALACAO.${RESET}"
        sleep 5
    fi
}

func_call_monitor() {
    func_download_exec "$MONITOR_LOCAL" "$REPO_BASE/onlinexray.sh" "Monitor Online"
}

# --- CERTIFICADO EXTERNO ---
func_xray_cert() {
    local domain_arg="$1"
    func_download_exec "$CERT_LOCAL" "$REPO_BASE/certxray.sh" "Certificados SSL" "$domain_arg"
}

# --- MODULOS EXTERNOS (AGORA COM CACHE) ---
func_module_block() {
    func_download_exec "$BLOCK_LOCAL" "$REPO_BASE/block_user.sh" "Bloqueador"
}

func_module_unblock() {
    func_download_exec "$UNBLOCK_LOCAL" "$REPO_BASE/unblock_user.sh" "Desbloqueador"
}

func_install_bot() {
    func_download_exec "$BOT_SHELL_LOCAL" "$REPO_BASE/botxray.sh" "Instalador do Bot"
}

# --- BACKUP ---
func_backup_system() {
    clear
    header_blue "SISTEMA DE BACKUP"
    echo "Isso ira salvar:"
    echo " - Banco de Dados"
    echo " - Configs e Certificados"
    echo ""
    echo -e "${TXT_CYAN}[1] CRIAR NOVO BACKUP${RESET}"
    echo -e "${TXT_CYAN}[0] VOLTAR${RESET}"
    echo ""
    read -rp "Opcao: " bkp_opt

    if [[ "$bkp_opt" != "1" ]]; then return; fi

    local backup_dir="/root/backups"
    local date_now=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/backup_dragoncore_${date_now}.tar.gz"
    local filename=$(basename "$backup_file")
    
    mkdir -p "$backup_dir"
    echo ""
    echo "Criando backup..."
    
    if [ ! -f "/opt/XrayTools/users.db" ] && [ ! -d "/usr/local/etc/xray" ]; then
        echo -e "${TXT_RED}Erro: Arquivos nao encontrados!${RESET}"
        read -rp "Enter..."
        return
    fi

    # Importante: users.db primeiro para garantir integridade
    tar -czPf "$backup_file" /opt/XrayTools /usr/local/etc/xray > /dev/null 2>&1

    if [ -f "$backup_file" ]; then
        echo ""
        echo "Limpando backups antigos..."
        find "$backup_dir" -name "*.tar.gz" -type f ! -name "$filename" -delete
        echo -e "${TXT_GREEN}BACKUP CRIADO!${RESET}"
        echo -e "Arquivo: ${TXT_CYAN}$filename${RESET}"
    else
        echo -e "${TXT_RED}Falha ao criar backup.${RESET}"
    fi
    echo "========================================="
    read -rp "Enter para voltar..."
}

# --- RESTAURACAO ---
func_restore_system() {
    clear
    header_red "RESTAURACAO DE SISTEMA"
    local backup_dir="/root/backups"

    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir"/*.tar.gz 2>/dev/null)" ]; then
        echo -e "${TXT_YELLOW}AVISO:${RESET} Nenhum backup encontrado."
        read -rp "Enter para voltar..."
        return
    fi

    echo -e "${TXT_YELLOW}ATENCAO:${RESET} Substituira dados atuais."
    echo ""
    shopt -s nullglob
    local backups=("$backup_dir"/*.tar.gz)
    shopt -u nullglob
    local total_backups=${#backups[@]}
    local selected_file=""

    if [ "$total_backups" -eq 1 ]; then
        selected_file="${backups[0]}"
        echo -e "Backup: ${TXT_CYAN}$(basename "$selected_file")${RESET}"
        echo ""
        read -rp "Restaurar agora? [s/n]: " confirm_auto
        if [[ "$confirm_auto" != "s" ]]; then return; fi
    else
        echo "Backups encontrados:"
        local i=1
        for bkp in "${backups[@]}"; do
            echo -e "${TXT_CYAN}[$i]${RESET} $(basename "$bkp")"
            ((i++))
        done
        echo ""
        read -rp "Escolha o numero (0 cancela): " choice
        if [ "$choice" == "0" ] || [ -z "$choice" ]; then return; fi
        local index=$((choice - 1))
        selected_file="${backups[$index]}"
    fi

    echo "Restaurando..."
    systemctl stop xray
    systemctl stop botxray
    tar -xzPf "$selected_file" -C /
    if [ $? -eq 0 ]; then
        systemctl restart xray
        systemctl restart botxray
        echo -e "${TXT_GREEN}RESTAURACAO CONCLUIDA!${RESET}"
    else
        echo -e "${TXT_RED}Falha critica.${RESET}"
        systemctl start xray
    fi
    read -rp "Enter para voltar..."
}

# --- GERACAO DE CONFIG ---
func_generate_config() {
    local port="$1"
    local network="$2"
    local domain="$3"
    local api_port="$4"
    local use_tls="$5" 
    
    mkdir -p "$(dirname "$CONFIG_PATH")"
    local stream_settings=""
    local policy='{"levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}}, "system": {"statsInboundUplink": true, "statsInboundDownlink": true}}'

    local routing_rules='[
        {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
        {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"},
        {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}
    ]'

    if [ "$network" == "xhttp" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{
                network: "xhttp", 
                security: "tls", 
                tlsSettings: {
                    serverName: $dom, 
                    certificates: [{certificateFile: $crt, keyFile: $key}], 
                    alpn: ["h2", "http/1.1"]
                }, 
                xhttpSettings: {
                    path: "/", 
                    scMaxBufferedPosts: 30, 
                    scMaxEachPostBytes: "1000000",
                    scStreamUpServerSecs: "20-80", 
                    xPaddingBytes: "100-1000"
                }
            }')
        else
            stream_settings=$(jq -n \
            '{
                network: "xhttp", 
                security: "none", 
                xhttpSettings: {
                    path: "/", 
                    scMaxBufferedPosts: 30, 
                    scMaxEachPostBytes: "1000000",
                    scStreamUpServerSecs: "20-80", 
                    xPaddingBytes: "100-1000"
                }
            }')
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

    jq -n --argjson stream "$stream_settings" --arg port "$port" --arg api "$api_port" --argjson pol "$policy" --argjson rules "$routing_rules" \
      '{log: {loglevel: "warning"}, stats: {}, api: {services: ["HandlerService", "LoggerService", "StatsService"], tag: "api"}, policy: $pol, inbounds: [{tag: "api", port: ($api | tonumber), protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, listen: "127.0.0.1"}, {tag: "inbound-dragoncore", port: ($port | tonumber), protocol: "vless", settings: {clients: [], decryption: "none", fallbacks: []}, streamSettings: $stream}], outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "blocked"}], routing: {domainStrategy: "AsIs", rules: $rules}}' > "$CONFIG_PATH"

    if [ "$network" == "vision" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow": "xtls-rprx-vision"}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    local preset_file="/usr/local/etc/xray/preset.json"
    cat > "$preset_file" <<EOF
{
  "network": "$network",
  "port": "$port",
  "domain": "$domain",
  "tls": "$use_tls"
}
EOF

    systemctl restart xray > /dev/null 2>&1
    sleep 2
    
    # --- RESULTADO FINAL ---
    clear
    header_blue "INSTALACAO CONCLUIDA COM SUCESSO"
    
    if systemctl is-active --quiet xray; then
        echo -e "STATUS: ${TXT_GREEN}ATIVO E RODANDO${RESET}"
    else
        echo -e "STATUS: ${TXT_RED}FALHA AO INICIAR${RESET}"
        journalctl -u xray -n 5 --no-pager
    fi

    local tls_msg="${TXT_RED}DESATIVADO${RESET}"
    if [ "$use_tls" == "true" ]; then tls_msg="${TXT_GREEN}ATIVADO (TLS/SSL)${RESET}"; fi

    echo ""
    echo "========================================="
    echo -e " ${TXT_YELLOW}PROTOCOLO:${RESET}        ${TXT_CYAN}${network^^}${RESET}"
    echo -e " ${TXT_YELLOW}DOMINIO (SNI):${RESET}    ${TXT_CYAN}${domain}${RESET}"
    echo -e " ${TXT_YELLOW}PORTA:${RESET}            ${TXT_CYAN}${port}${RESET}"
    echo -e " ${TXT_YELLOW}CRIPTOGRAFIA:${RESET}     ${tls_msg}"
    echo -e " ${TXT_YELLOW}PROTEÇÃO:${RESET}         ${TXT_GREEN}TORRENT & LAN BLOQUEADOS${RESET}"
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

    echo -e "${TXT_YELLOW}UUID UNIVERSAL:${RESET}"
    echo -e "${TXT_CYAN}${universal_uuid}${RESET}"
    echo ""
    echo -e "${TXT_YELLOW}LINK VLESS (TEMPLATE):${RESET}"
    echo -e "${TXT_BLUE}$link${RESET}"
    echo ""
    echo "========================================="
    echo "NOTA: Crie um usuario real na Opcao 1."
    echo "========================================="
    read -rp "Enter para finalizar..."
}

func_page_create_user() {
    header_blue "CRIAR NOVO USUÁRIO"
    echo "⚠️  Regras para o nome:"
    echo " • Mínimo 5 e Máximo 9 caracteres"
    echo " • Apenas letras e números (sem símbolos)"
    echo ""
    
    echo -e "${TXT_YELLOW}DIGITE O NOME DO USUÁRIO (0 p/ voltar):${RESET}"
    read -rp "Nome: " raw_nick
    
    if [ "$raw_nick" == "0" ] || [ -z "$raw_nick" ]; then return; fi

    # Validação Rigorosa
    if ! [[ "$raw_nick" =~ ^[a-zA-Z0-9]{5,9}$ ]]; then
        echo ""
        echo -e "${TXT_RED}❌ ERRO: Formato inválido!${RESET}"
        echo "O usuário deve ter entre 5 e 9 caracteres."
        echo "Use apenas letras e números."
        echo ""
        read -rp "Pressione ENTER para tentar novamente..."
        return
    fi

    # --- CORREÇÃO AQUI (Adicionado ^ e |) ---
    # O ^ significa "começo da linha" e o | é o separador.
    # Assim 'joaop' não confunde com 'joaopaulo'
    if grep -q "^$raw_nick|" "$USER_DB"; then 
        echo -e "${TXT_RED}❌ Usuário já existe!${RESET}"
        sleep 2
        return
    fi
    
    echo ""
    echo -e "${TXT_YELLOW}DIGITE OS DIAS DE VALIDADE (Padrão 30):${RESET}"
    read -rp "Dias: " days
    [ -z "$days" ] && days=30
    
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then days=30; fi

    func_add_user_logic "$raw_nick" "$days"
    read -rp "Pressione ENTER para voltar ao menu..."
}

func_add_user_logic() {
    local nick="$1"
    local expiry_days="$2"
    if [ -z "$nick" ]; then return 1; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "Erro config."; return 1; fi
    
    # --- CORREÇÃO DE SEGURANÇA EXTRA ---
    # Garante que não duplique mesmo se passar pela validação visual
    if grep -q "^$nick|" "$USER_DB"; then
        echo "Erro: Usuario duplicado no DB."
        return 1
    fi

    local uuid=$(uuidgen)
    local expiry=$(date -d "+$expiry_days days" +%F)
    
    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
        '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) += [{"id": $uuid, "email": $nick_arg, "level": 0}]' \
        "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        
    echo "$nick|$uuid|$expiry" >> "$USER_DB"
    systemctl restart xray > /dev/null 2>&1
    clear
    echo -e "${TXT_GREEN}Usuario criado!${RESET}"
    echo "-----------------------------------------"
    echo -e "User: ${TXT_CYAN}$nick${RESET}"
    echo -e "UUID: ${TXT_YELLOW}$uuid${RESET}"
    echo -e "Expira: $expiry"
    echo "-----------------------------------------"
}

func_remove_user_logic() {
    local identifier="$1"
    if [ ! -f "$CONFIG_PATH" ]; then echo "Erro config."; return; fi
    
    # Remove do JSON (Aqui o jq já é seguro pois busca match exato do campo email)
    jq --arg id "$identifier" \
        '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(select(.id != $id and .email != $id))' \
        "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    # --- CORREÇÃO NO BANCO DE DADOS (SED) ---
    # Adicionado ^ e | para garantir que apague apenas o usuário exato
    if [ -f "$USER_DB" ]; then 
        sed -i "/^$identifier|/d" "$USER_DB"
        # Backup: tenta apagar também pelo UUID (caso o input seja UUID)
        sed -i "/|$identifier|/d" "$USER_DB"
    fi
    
    systemctl restart xray > /dev/null 2>&1
    echo -e "${TXT_GREEN}Removido.${RESET}"; sleep 1
}

# --- ASSISTENTE DE INSTALACAO (WIZARD DETALHADO) ---
func_wizard_install() {
    clear
    header_blue "PASSO 1: INSTALACAO DO NUCLEO"
    echo -e "${TXT_YELLOW}DESEJA INSTALAR OU ATUALIZAR O XRAY CORE AGORA?${RESET}"
    echo "Isso ira baixar a versao oficial mais recente."
    echo ""
    read -rp "Digite [s] para SIM ou [n] para NÃO: " install_opt
    if [[ "$install_opt" =~ ^[Ss]$ ]]; then func_install_official_core; fi

    clear
    header_blue "PASSO 2: CRIPTOGRAFIA E SEGURANCA"
    echo -e "${TXT_YELLOW}DESEJA UTILIZAR CRIPTOGRAFIA TLS/SSL (HTTPS)?${RESET}"
    echo "Recomendado para: SNI, CDN (Cloudflare/Azion)."
    echo ""
    echo " [1] SIM - (MODO SEGURO / SUPREMO)"
    echo " [2] NAO - (MODO SIMPLES / HTTP)"
    echo ""
    read -rp "Escolha uma opcao [1-2]: " tls_opt
    local use_tls="false"
    if [ "$tls_opt" == "1" ]; then use_tls="true"; fi

    clear
    header_blue "PASSO 3: PORTAS DE CONEXAO"
    echo -e "${TXT_YELLOW}DIGITE A PORTA INTERNA DO XRAY (API):${RESET}"
    echo "Padrao: 1080 (Se tiver duvidas, aperte ENTER)"
    read -rp "Porta Interna: " api_port
    if [ -z "$api_port" ]; then api_port="1080"; fi
    
    echo ""
    echo -e "${TXT_YELLOW}DIGITE A PORTA DE CONEXAO PUBLICA (LISTEN):${RESET}"
    echo "Exemplos: 80 (Para sem TLS) ou 443 (Para com TLS)"
    read -rp "Porta Publica: " pub_port
    if [ -z "$pub_port" ]; then pub_port="80"; fi

    echo "Verificando disponibilidade da porta $pub_port..."
    if lsof -Pi :$pub_port -sTCP:LISTEN -t >/dev/null ; then
        echo ""
        echo -e "${TXT_RED}❌ ERRO CRÍTICO: A PORTA $pub_port JÁ ESTÁ EM USO!${RESET}"
        echo "Serviço ocupando a porta:"
        lsof -i :$pub_port
        echo ""
        echo "Pare o serviço conflitante (Apache/Nginx) ou escolha outra porta."
        read -rp "Pressione ENTER para voltar..."
        return
    fi

    clear
    header_blue "PASSO 4: DOMINIO E SNI"
    local domain_val=""
    
    if [ "$use_tls" == "true" ]; then
        echo -e "${TXT_GREEN}MODO SUPREMO ATIVADO!${RESET}"
        echo -e "${TXT_YELLOW}DIGITE O SEU DOMINIO OU SUBDOMINIO:${RESET}"
        echo "Exemplo: suacdn.azion.app ou vpn.site.com"
        echo "AVISO: O dominio deve estar apontado para este IP!"
        echo ""
        read -rp "Dominio: " domain_val
        
        if [ -n "$domain_val" ]; then
            func_xray_cert "$domain_val"
        else
            echo "Dominio vazio, pulando etapa do certxray..."
        fi

    else
        echo "Modo sem TLS selecionado."
        echo -e "${TXT_YELLOW}DIGITE O DOMINIO OU IP DA VPS:${RESET}"
        read -rp "Endereco: " domain_val
        if [ -z "$domain_val" ]; then domain_val=$(curl -s icanhazip.com); fi
    fi
    
    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"

    clear
    header_blue "PASSO 5: PROTOCOLO DE TRANSPORTE"
    echo -e "${TXT_YELLOW}QUAL PROTOCOLO VOCE DESEJA UTILIZAR?${RESET}"
    echo ""
    echo " [1] WS      (WEBSOCKET - Compativel com tudo)"
    echo " [2] GRPC    (GRPC - Baixa latencia)"
    echo " [3] XHTTP   (HTTP/2 - Novo padrao)"
    echo " [4] TCP     (TCP HTTP - Simples)"
    echo " [5] VISION  (XTLS-VISION - Reality/Direct)"
    echo " [0] CANCELAR"
    echo ""
    read -rp "Escolha uma opcao [1-5]: " prot_opt
    
    local selected_net=""
    case "$prot_opt" in
        1) selected_net="ws" ;;
        2) selected_net="grpc" ;;
        3) selected_net="xhttp" ;;
        4) selected_net="tcp" ;;
        5) 
            selected_net="vision"
            if [ "$use_tls" == "false" ]; then
                echo ""
                echo -e "${TXT_YELLOW}VISION EXIGE TLS! VAMOS CONFIGURAR:${RESET}"
                read -rp "Digite um Dominio Fake (Ex: microsoft.com): " domain_val
                func_xray_cert "$domain_val"; use_tls="true"; echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"
            fi ;;
        0) return ;;
        *) echo "Opcao Invalida."; sleep 2; return ;;
    esac

    func_generate_config "$pub_port" "$selected_net" "$domain_val" "$api_port" "$use_tls"
}

func_page_remove_user() {
    header_blue "REMOVER USUARIO"
    read -rp "Nome ou UUID: " id_input
    if [ -n "$id_input" ]; then func_remove_user_logic "$id_input"; fi
}

func_page_list_users() {
    header_blue "LISTA"
    printf "%-15s | %-37s | %s\n" "USER" "UUID" "EXPIRA"
    echo "-----------------------------------------------------------------------"
    if [ -f "$USER_DB" ]; then
        while IFS='|' read -r nick uuid expiry; do
            if [ -n "$nick" ]; then printf "%-15s | %-37s | %s\n" "$nick" "$uuid" "$expiry"; fi
        done < "$USER_DB"
    else echo "Vazio."; fi
    echo "-----------------------------------------------------------------------"
    echo ""; read -rp "Enter para voltar..."
}

func_page_purge_expired() {
    header_blue "LIMPEZA DE EXPIRADOS"
    
    local today=$(date +%F)
    local count=0
    local found_expired=false

    echo -e "${TXT_YELLOW}Verificando banco de dados...${RESET}"
    echo ""
    
    if [ ! -f "$USER_DB" ]; then
        echo "Banco de dados vazio."
        read -rp "Pressione ENTER..."
        return
    fi

    printf "%-20s | %s\n" "USUÁRIO" "VENCIMENTO"
    echo "-----------------------------------"

    while IFS='|' read -r nick uuid expiry; do
        if [[ "$expiry" < "$today" ]]; then
            printf "${TXT_RED}%-20s${RESET} | ${TXT_RED}%s${RESET}\n" "$nick" "$expiry"
            found_expired=true
            ((count++))
        fi
    done < "$USER_DB"

    echo "-----------------------------------"
    echo ""

    if [ "$found_expired" = false ]; then
        echo -e "${TXT_GREEN}✅ Nenhum usuário vencido encontrado!${RESET}"
        echo "Todos os clientes estão com dias ativos."
        echo ""
        read -rp "Pressione ENTER para voltar..."
        return
    fi

    echo -e "Foram encontrados ${TXT_RED}$count usuários vencidos${RESET}."
    echo -e "${TXT_YELLOW}⚠️  ATENÇÃO: A remoção é IRREVERSÍVEL!${RESET}"
    echo ""
    read -rp "Deseja realmente excluir estes usuários? [s/n]: " confirm

    if [[ "$confirm" != "s" ]]; then
        echo ""
        echo "Operação cancelada. Nenhum usuário foi removido."
        sleep 2
        return
    fi

    echo ""
    echo "Limpando sistema..."
    
    > "${USER_DB}.tmp"

    while IFS='|' read -r nick uuid expiry; do
        if [[ "$expiry" < "$today" ]]; then
            echo -e "Removendo: ${TXT_RED}$nick${RESET}..."
            jq --arg id "$uuid" '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(select(.id != $id))' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        else
            echo "$nick|$uuid|$expiry" >> "${USER_DB}.tmp"
        fi
    done < "$USER_DB"

    mv "${USER_DB}.tmp" "$USER_DB"
    systemctl restart xray > /dev/null 2>&1

    echo ""
    echo -e "${TXT_GREEN}✅ LIMPEZA CONCLUÍDA!${RESET}"
    echo "Os usuários expirados foram removidos do sistema."
    echo "========================================="
    read -rp "Pressione ENTER para voltar..."
}

func_page_uninstall() {
    clear
    header_red "⚠️  DESINSTALAÇÃO E LIMPEZA TOTAL ⚠️"
    echo -e "${TXT_RED}ATENÇÃO:${RESET} Esta ação é irreversível."
    echo "Isso irá remover:"
    echo " • O Xray Core, Configs, Usuários e Logs"
    echo " • O Bot Telegram e Backups"
    echo " • Certificados SSL e configurações do Certbot"
    echo " • FAXINA PROFUNDA (Snaps antigos, Cache APT, Logs)"
    echo ""
    read -rp "Tem certeza que deseja continuar? [s/n]: " confirm
    
    if [[ "$confirm" != "s" ]]; then return; fi

    local domain_rem=""
    if [ -f "/usr/local/etc/xray/preset.json" ]; then
        domain_rem=$(grep -oP '"domain": "\K[^"]+' /usr/local/etc/xray/preset.json)
    fi
    if [ -z "$domain_rem" ] && [ -f "$ACTIVE_DOMAIN_FILE" ]; then
        domain_rem=$(cat "$ACTIVE_DOMAIN_FILE")
    fi

    echo ""
    echo "1. Parando serviços..."
    systemctl stop xray > /dev/null 2>&1
    systemctl disable xray > /dev/null 2>&1
    systemctl stop botxray > /dev/null 2>&1
    systemctl disable botxray > /dev/null 2>&1

    echo "2. Removendo arquivos do Xray e Certificados..."
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/botxray.service
    systemctl daemon-reload

    rm -rf /usr/local/bin/xray
    rm -rf /usr/local/share/xray
    rm -rf /usr/local/etc/xray
    rm -rf /var/log/xray
    rm -rf /opt/XrayTools
    rm -rf /root/backups 
    rm -rf /opt/DragonCoreSSL

    # Remove os scripts em cache (ADICIONE AQUI NO FINAL)
    rm -f "$LIMITER_LOCAL" "$MONITOR_LOCAL" "$BLOCK_LOCAL" "$UNBLOCK_LOCAL" "$CERT_LOCAL" "$BOT_SHELL_LOCAL"

    if command -v certbot &> /dev/null; then
        if [ ! -z "$domain_rem" ]; then
            echo "   - Removendo certificado do domínio: $domain_rem..."
            certbot delete --cert-name "$domain_rem" --non-interactive > /dev/null 2>&1
        else
            echo "   - Domínio não detectado, pulando limpeza do Certbot."
        fi
    fi

    echo "3. Limpando agendamentos (Cron)..."
    crontab -l 2>/dev/null | grep -v "menuxray" | grep -v "limiter" | grep -v "renew_cert.sh" | crontab -
    
    echo "4. Removendo atalhos..."
    rm -f /usr/bin/xray-menu
    rm -f /usr/local/bin/uuidgen

    echo "5. Executando limpeza profunda de disco..."
    
    echo "   - Limpando cache e listas do APT..."
    apt-get clean > /dev/null 2>&1
    apt-get autoremove -y > /dev/null 2>&1
    rm -rf /var/lib/apt/lists/*

    echo "   - Zerando logs do sistema e temporários..."
    rm -rf /tmp/*
    journalctl --vacuum-time=1s > /dev/null 2>&1

    if command -v snap > /dev/null 2>&1; then
        echo "   - Removendo revisões antigas do Snap (Isso libera muito espaço)..."
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | \
        while read snapname revision; do
            snap remove "$snapname" --revision="$revision" > /dev/null 2>&1
        done
    fi

    echo ""
    echo "========================================="
    echo -e "${TXT_GREEN}✅ DESINSTALAÇÃO E LIMPEZA CONCLUÍDAS!${RESET}"
    echo "Seu disco foi totalmente liberado e certificados removidos."
    echo "========================================="
    echo ""
    
    exit 0
}

func_call_limiter() {
    echo "Verificando Limitador..."
    if [ -f "$CONFIG_PATH" ]; then
        if ! grep -q '"stats":' "$CONFIG_PATH"; then
            systemctl stop xray
            jq '.stats = {}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            systemctl restart xray
        fi
    fi
    func_download_exec "$LIMITER_LOCAL" "$REPO_BASE/limiterxray.sh" "Limitador"
}

# --- MENU PRINCIPAL ---
menu_display() {
    clear
    echo -e "${TITLE_BAR}        DRAGONCORE XRAY MANAGER        ${RESET}"
    echo ""
    
    local status_txt="${TXT_RED}DESATIVADO${RESET}"
    local proto_info="${TXT_RED}---${RESET}"
    local users_count="0"
    local preset_file="/usr/local/etc/xray/preset.json"
    local port="?"
    
    if [ -f "$USER_DB" ]; then users_count=$(wc -l < "$USER_DB"); fi

    if systemctl is-active --quiet xray; then
        status_txt="${TXT_GREEN}ATIVADO${RESET}"
        
        if [ -f "$preset_file" ]; then
            local net=$(jq -r '.network' "$preset_file" 2>/dev/null)
            port=$(jq -r '.port' "$preset_file" 2>/dev/null)
            
            if [ -z "$net" ] || [ "$net" == "null" ]; then
                 net=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.network' "$CONFIG_PATH" 2>/dev/null)
                 port=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").port' "$CONFIG_PATH" 2>/dev/null)
            fi
            
            [ -z "$port" ] && port="?"
            [ -z "$net" ] && net="?"
            proto_info="${TXT_CYAN}${net^^}${RESET} (Porta: ${TXT_CYAN}$port${RESET})"
        fi
    fi

    local bot_status="${TXT_RED}DESATIVADO${RESET}"
    if systemctl is-active --quiet botxray; then
        bot_status="${TXT_GREEN}ATIVADO${RESET}"
    fi

    local online_count="00"
    local clean_port=$(echo "$port" | tr -dc '0-9')
    if [ -n "$clean_port" ] && [ "$clean_port" != "?" ]; then
          online_count=$(ss -tn state established "sport = :$clean_port" | awk '{print $5}' | sed 's/:[^:]*$//' | sort | uniq | wc -l)
          online_count=$(printf "%02d" $online_count)
    fi

    echo "-----------------------------------------"
    echo -e "${TXT_CYAN}XRAY:${RESET}        $status_txt"
    echo -e "${TXT_CYAN}USUÁRIOS:${RESET}    $users_count"
    echo -e "${TXT_CYAN}IPs ATIVOS:${RESET}  $online_count"
    echo -e "${TXT_CYAN}INFO:${RESET}        $proto_info"
    echo -e "${TXT_CYAN}BOT XRAY:${RESET}    $bot_status"
    echo "-----------------------------------------"
    echo ""
    echo -e "${TXT_CYAN}[01] CRIAR USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[02] REMOVER USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[03] LISTAR USUARIOS${RESET}"
    echo -e "${TXT_CYAN}[04] INSTALAR/CONFIGURAR XRAY${RESET}"
    echo -e "${TXT_CYAN}[05] LIMPAR EXPIRADOS${RESET}"
    echo -e "${TXT_CYAN}[06] DESINSTALAR XRAY${RESET}"
    echo -e "${TXT_CYAN}[07] LIMITADOR CONSUMO (GB)${RESET}"
    echo -e "${TXT_CYAN}[08] BOT TELEGRAM${RESET}"
    echo -e "${TXT_CYAN}[09] CRIAR BACKUP${RESET}"      
    echo -e "${TXT_CYAN}[10] RESTAURAR BACKUP${RESET}" 
    echo -e "${TXT_CYAN}[11] BLOQUEAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[12] DESBLOQUEAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[13] MONITOR ONLINE (REAL TIME)${RESET}"
    echo -e "${TXT_CYAN}[00] SAIR${RESET}"
    echo "-----------------------------------------"
    read -rp "Opcao: " choice
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
            13) func_call_monitor ;;
            0) exit 0 ;;
        esac
    done
else "$1" "${@:2}"; 
fi
