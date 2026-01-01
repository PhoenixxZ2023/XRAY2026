#!/bin/bash
# menuxray.sh - Versão V6.2 (Listagem Direta JSON + Azion Fix)

# --- CONFIGURAÇÃO AUTOMÁTICA ---
DB_HOST="localhost"
DB_NAME="sshplus" 
DB_USER="root"
DB_PASS="null"

XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"
XRAY_DIR="/opt/XrayTools"
ACTIVE_DOMAIN_FILE="$XRAY_DIR/active_domain"

export PGPASSWORD=$DB_PASS
mkdir -p "$XRAY_DIR"
mkdir -p "$SSL_DIR"

# --- CORES E VISUAL ---
TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_BLUE='\033[1;34m'
TXT_CYAN='\033[1;36m'
RESET='\033[0m'

header_blue() {
    clear
    echo -e "${TITLE_BAR}   $1   ${RESET}"
    echo ""
}

# --- FUNÇÃO DE BANCO DE DADOS (Mantida para compatibilidade) ---
db_query() {
    local query="$1"
    local result=""
    result=$(psql -h "localhost" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$query" 2>/dev/null)
    if [ -z "$result" ]; then result=$(sudo -u postgres psql -d sshplus -t -A -c "$query" 2>/dev/null); fi
    if [ -z "$result" ]; then result=$(sudo -u postgres psql -d dtunnel -t -A -c "$query" 2>/dev/null); fi
    if [ -z "$result" ]; then result=$(sudo -u postgres psql -d xray -t -A -c "$query" 2>/dev/null); fi
    echo "$result"
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
    chmod 755 "$SSL_DIR"; chmod 644 "$KEY_FILE"; chmod 644 "$CRT_FILE"
}

func_generate_config() {
    local port="$1"
    local network="$2"
    local domain="$3"
    local api_port="$4"
    local use_tls="$5" 
    
    mkdir -p "$(dirname "$CONFIG_PATH")"
    local stream_settings=""
    
    # --- LOGICA DE PROTOCOLOS ---
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

    jq -n --argjson stream "$stream_settings" --arg port "$port" --arg api "$api_port" \
      '{log: {loglevel: "warning"}, api: {services: ["HandlerService", "LoggerService", "StatsService"], tag: "api"}, inbounds: [{tag: "api", port: ($api | tonumber), protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, listen: "127.0.0.1"}, {tag: "inbound-dragoncore", port: ($port | tonumber), protocol: "vless", settings: {clients: [], decryption: "none", fallbacks: []}, streamSettings: $stream}], outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "blocked"}], routing: {domainStrategy: "AsIs", rules: [{type: "field", inboundTag: ["api"], outboundTag: "api"}]}}' > "$CONFIG_PATH"

    if [ "$network" == "vision" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow": "xtls-rprx-vision"}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    systemctl restart xray > /dev/null 2>&1
    sleep 2
    clear
    header_blue "STATUS DA INSTALAÇÃO"
    if systemctl is-active --quiet xray; then
        echo -e "${TXT_GREEN}✅ Configuração Aplicada!${RESET}"
    else
        echo -e "${TXT_RED}❌ Falha ao iniciar.${RESET}"
        journalctl -u xray -n 5 --no-pager
    fi
    echo "========================================="
    read -rp "Pressione ENTER para voltar..."
}

func_add_user_logic() {
    local nick="$1"
    local expiry_days="$2"
    if [ -z "$nick" ]; then return 1; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "❌ Xray não configurado."; return 1; fi

    local port=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").port' "$CONFIG_PATH")
    local net=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.network' "$CONFIG_PATH")
    local sec=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.security' "$CONFIG_PATH")
    local domain=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.tlsSettings.serverName // empty' "$CONFIG_PATH")
    
    local vps_ip=$(curl -s icanhazip.com)
    if [ -z "$domain" ]; then domain=$vps_ip; fi

    local uuid=$(uuidgen)
    local expiry=$(date -d "+$expiry_days days" +%F)

    # Tenta salvar no DB, mas não depende disso
    db_query "CREATE TABLE IF NOT EXISTS xray (id SERIAL PRIMARY KEY, uuid TEXT, nick TEXT, expiry DATE, protocol TEXT, domain TEXT);" > /dev/null 2>&1

    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
       '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) += [{"id": $uuid, "email": $nick_arg, "level": 0}]' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    db_query "INSERT INTO xray (uuid, nick, expiry, protocol, domain) VALUES ('$uuid', '$nick', '$expiry', '$net', '$domain')"
    
    systemctl restart xray > /dev/null 2>&1
    
    # --- GERADOR DE LINK ---
    local link=""
    if [ "$net" == "grpc" ]; then
        local serviceName=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.grpcSettings.serviceName' "$CONFIG_PATH")
        link="vless://${uuid}@${vps_ip}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=${serviceName}&sni=${domain}#${nick}"
    elif [ "$net" == "ws" ]; then
        local path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.wsSettings.path' "$CONFIG_PATH")
        [ "$path" == "/" ] && path="%2F"
        link="vless://${uuid}@${vps_ip}:${port}?path=${path}&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#${nick}"
    elif [ "$net" == "xhttp" ]; then
        local path=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").streamSettings.xhttpSettings.path' "$CONFIG_PATH")
        [ "$path" == "/" ] && path="%2F"
        if [ "$sec" == "tls" ]; then
            link="vless://${uuid}@${vps_ip}:${port}?mode=auto&path=${path}&security=tls&encryption=none&host=${domain}&type=xhttp&sni=${domain}#${nick}"
        else
            link="vless://${uuid}@${vps_ip}:${port}?mode=auto&path=${path}&security=none&encryption=none&host=${domain}&type=xhttp#${nick}"
        fi
    elif [ "$net" == "tcp" ] || [ "$net" == "vision" ]; then
        local flow=$(jq -r '.inbounds[] | select(.tag == "inbound-dragoncore").settings.flow // empty' "$CONFIG_PATH")
        if [ "$flow" == "xtls-rprx-vision" ]; then
            link="vless://${uuid}@${vps_ip}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#${nick}"
        elif [ "$sec" == "tls" ]; then
            link="vless://${uuid}@${vps_ip}:${port}?security=tls&encryption=none&type=tcp&sni=${domain}#${nick}"
        else
            link="vless://${uuid}@${vps_ip}:${port}?security=none&encryption=none&type=tcp#${nick}"
        fi
    fi

    clear
    echo -e "${TXT_GREEN}✅ Usuário criado com sucesso!${RESET}"
    echo "-----------------------------------------"
    echo "👤 Usuário: $nick"
    echo "🔑 UUID:    $uuid"
    echo "-----------------------------------------"
    echo -e "${TXT_BLUE}🔗 Link de Conexão:${RESET}"
    echo "$link"
    echo "-----------------------------------------"
}

func_remove_user_logic() {
    local identifier="$1" # Pode ser UUID ou NOME
    
    if [ ! -f "$CONFIG_PATH" ]; then echo "❌ Erro config."; return; fi
    
    # Remove pelo JSON (Infalível)
    # Remove onde ID = identifier OU Email = identifier
    jq --arg id "$identifier" \
       '(.inbounds[] | select(.tag == "inbound-dragoncore").settings.clients) |= map(select(.id != $id and .email != $id))' \
       "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    # Tenta limpar do DB também só pra garantir
    db_query "DELETE FROM xray WHERE uuid = '$identifier' OR nick = '$identifier'"
    
    systemctl restart xray > /dev/null 2>&1
    echo -e "${TXT_GREEN}✅ Usuário removido (se existia).${RESET}"
    sleep 1
}

# --- PÁGINAS ---

func_page_create_user() {
    while true; do
        header_blue "CRIAR USUÁRIO"
        read -rp "Nome do usuário (0 p/ voltar): " nick
        if [ "$nick" == "0" ] || [ -z "$nick" ]; then break; fi
        # Verificação via JSON (Mais confiável que DB)
        if grep -q "$nick" "$CONFIG_PATH"; then echo "❌ Usuário já existe!"; sleep 1; continue; fi
        
        read -rp "Dias de validade (Padrão 30): " days
        [ -z "$days" ] && days=30
        func_add_user_logic "$nick" "$days"
        read -rp "Pressione ENTER para continuar..."
    done
}

func_page_remove_user() {
    header_blue "REMOVER USUÁRIO"
    echo "Digite o Nome (nick) ou UUID para remover."
    read -rp "Identificador: " id_input
    if [ -n "$id_input" ]; then func_remove_user_logic "$id_input"; fi
}

func_page_list_users() {
    if [ ! -f "$CONFIG_PATH" ]; then echo "❌ Xray não configurado."; read -rp "Enter..."; return; fi
    header_blue "LISTAR USUÁRIOS (ARQUIVO REAL)"
    
    echo -e "USUÁRIO        | UUID"
    echo "------------------------------------------------"
    
    # LÊ DIRETO DO ARQUIVO JSON (INFALÍVEL)
    jq -r '.inbounds[] | select(.settings.clients != null) | .settings.clients[] | "\(.email) | \(.id)"' "$CONFIG_PATH" | while IFS='|' read -r nick uuid; do
        if [ -n "$nick" ]; then
            printf "%-14s | %s\n" "$nick" "$uuid"
        fi
    done
    
    echo ""
    echo -e "${TXT_BLUE}ℹ️  Listagem direta do sistema (Config JSON).${RESET}"
    echo ""
    read -rp "Pressione ENTER para voltar..."
}

func_page_purge_expired() {
    header_blue "LIMPEZA DE EXPIRADOS"
    echo "⚠️  Função depende do Banco de Dados."
    local today=$(date +%F)
    local expired_uuids=$(db_query "SELECT uuid FROM xray WHERE expiry < '$today'")
    if [ -z "$expired_uuids" ]; then 
        echo "✅ Nenhum usuário expirado (no banco de dados)."
    else
        for uuid in $expired_uuids; do func_remove_user_logic "$uuid"; done
        echo "✅ Limpeza concluída."
    fi
    echo ""; read -rp "Pressione ENTER para voltar..."
}

func_page_uninstall() {
    header_blue "DESINSTALAR SISTEMA"
    echo "⚠️  ATENÇÃO: ISSO APAGARÁ TUDO!"
    read -rp "Deseja realmente desinstalar? [s/n]: " confirm
    if [[ "$confirm" =~ ^[sS]$ ]]; then
        echo "🚀 Iniciando desinstalação..."
        systemctl stop xray > /dev/null 2>&1
        systemctl disable xray > /dev/null 2>&1
        rm -rf /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray /etc/systemd/system/xray* "$XRAY_DIR" "$SSL_DIR" /bin/xray-menu
        systemctl daemon-reload > /dev/null 2>&1
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;" >/dev/null 2>&1
        echo "✅ Desinstalação Completa!"; exit 0
    fi
}

func_wizard_install() {
    # PASSO 1
    header_blue "INSTALAÇÃO GUIADA (1/5)"
    read -rp "Deseja instalar/atualizar o Xray Core? [s/n]: " install_opt
    if [[ "$install_opt" =~ ^[Ss]$ ]]; then func_install_official_core; fi

    # PASSO 2
    header_blue "CONFIGURAÇÃO (2/5)"
    echo "Deseja usar criptografia TLS/SSL (HTTPS)?"
    echo "1) SIM - (SUPREMO/AZION: Aceita domínio Fake/Azion)"
    echo "2) NÃO - Conexão simples"
    read -rp "Opção [1/2]: " tls_opt
    local use_tls="false"
    if [ "$tls_opt" == "1" ]; then use_tls="true"; fi

    # PASSO 3
    header_blue "CONFIGURAÇÃO (3/5)"
    read -rp "Digite a porta interna do Xray [Padrão 1080]: " api_port
    if [ -z "$api_port" ]; then api_port="1080"; fi

    # PASSO 4
    header_blue "CONFIGURAÇÃO (4/5)"
    read -rp "Digite a porta de conexão pública (Ex: 443, 80): " pub_port
    if [ -z "$pub_port" ]; then pub_port="80"; fi

    # PASSO 5
    header_blue "CONFIGURAÇÃO (5/5)"
    local domain_val=""
    if [ "$use_tls" == "true" ]; then
        echo -e "${TXT_CYAN}MODO SUPREMO ATIVADO!${RESET}"
        echo "Digite seu domínio Azion ou Domínio Fake."
        echo "Ex: turbonet.azion.app ou www.batata.com"
        read -rp "Domínio: " domain_val
        func_xray_cert "$domain_val" 
    else
        echo "ℹ️  Modo sem TLS."
        read -rp "Digite o Domínio ou IP: " domain_val
        if [ -z "$domain_val" ]; then domain_val=$(curl -s icanhazip.com); fi
    fi
    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"

    header_blue "SELECIONE O PROTOCOLO"
    echo "1. ws (WebSocket)"
    echo "2. grpc (gRPC)"
    echo "3. xhttp (HTTP/2) - (Ideal para Azion/443)"
    echo "4. tcp (Simples)"
    echo "5. vision (XTLS-Vision) - 🚀"
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
                echo "⚠️  Vision exige TLS. Digite um domínio Fake:"
                read -rp "Domínio: " domain_val
                func_xray_cert "$domain_val"
                use_tls="true"
                echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"
            fi
            ;;
        0) return ;;
        *) echo "❌ Inválido."; sleep 2; return ;;
    esac

    func_generate_config "$pub_port" "$selected_net" "$domain_val" "$api_port" "$use_tls"
}

# --- MENU PRINCIPAL UI ---
menu_display() {
    clear
    echo -e "${TITLE_BAR}        DRAGONCORE XRAY MANAGER        ${RESET}"
    echo ""

    local status_txt="${TXT_RED}DESATIVADO${RESET}"
    local proto_info="${TXT_RED}---${RESET}"
    
    # Contagem via JSON (Mais precisa)
    local users_count="0"
    if [ -f "$CONFIG_PATH" ]; then
        users_count=$(jq '.inbounds[] | select(.settings.clients != null) | .settings.clients | length' "$CONFIG_PATH")
    fi
    [ -z "$users_count" ] && users_count="0"

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
    echo -e "${TXT_CYAN}[1]. CRIAR USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[2]. REMOVER USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[3]. LISTAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[4]. INSTALAR E CONFIGURAR XRAY (ASSISTENTE)${RESET}"
    echo -e "${TXT_CYAN}[5]. LIMPAR EXPIRADOS${RESET}"
    echo -e "${TXT_CYAN}[6]. DESINSTALAR (COMPLETO)${RESET}"
    echo -e "${TXT_CYAN}[0]. SAIR${RESET}"
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
            0) exit 0 ;;
        esac
    done
else "$1" "${@:2}"; 
fi
