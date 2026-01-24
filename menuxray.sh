#!/bin/bash
# xraymenu.sh - V7.4 (Seguro / Hardening mínimo)
# Baseado no menuxray.sh do DragonCore Xray Manager
# Principais correções: curl -fsSL, TLS minVersion 1.2, remove allowInsecure,
# pin por commit/tag (opcional), remoção DB sem sed-regex, modo estrito e validações.

set -euo pipefail

# ---- TRAP DE ERRO (para não "sumir" falhas) ----
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO. Abortando."; exit 1' ERR

# --- CONFIGURACAO ---
XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"
XRAY_DIR="/opt/XrayTools"
ACTIVE_DOMAIN_FILE="$XRAY_DIR/active_domain"
USER_DB="$XRAY_DIR/users.db"

# CAMINHOS LOCAIS PARA CACHE
LIMITER_LOCAL="/usr/local/bin/limiterxray.sh"
MONITOR_LOCAL="/usr/local/bin/onlinexray.sh"
BLOCK_LOCAL="/usr/local/bin/block_user.sh"
UNBLOCK_LOCAL="/usr/local/bin/unblock_user.sh"
CERT_LOCAL="/usr/local/bin/certxray.sh"
BOT_SHELL_LOCAL="/usr/local/bin/botxray.sh"

# URLS GITHUB (PINAGEM OPCIONAL)
REPO_OWNER="PhoenixxZ2023"
REPO_NAME="XrayX-TLS"

# Para ficar seguro de verdade: coloque um commit SHA aqui (ex.: "f4bbbe9...")
# Se ficar "main", ainda existe risco supply chain.
PINNED_REF="main"

REPO_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${PINNED_REF}"

# SHA256 OPCIONAIS (recomendado preencher quando usar versão/tag/commit fixo)
SHA_LIMITER=""
SHA_MONITOR=""
SHA_BLOCK=""
SHA_UNBLOCK=""
SHA_CERT=""
SHA_BOT=""

# ---- CORES/UI ----
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

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${TXT_RED}Execute como root.${RESET}"
        exit 1
    fi
}

apt_install() {
    local pkgs=("$@")
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "${pkgs[@]}" >/dev/null 2>&1
}

ensure_cmd() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        apt_install "$pkg"
    fi
}

validate_port() {
    local p="$1"
    if ! [[ "$p" =~ ^[0-9]{1,5}$ ]]; then
        return 1
    fi
    if (( p < 1 || p > 65535 )); then
        return 1
    fi
    return 0
}

sha256_check_optional() {
    local file_path="$1"
    local expected="$2"
    if [ -n "$expected" ]; then
        echo "${expected}  ${file_path}" | sha256sum -c - >/dev/null 2>&1
    fi
}

download_file_strict() {
    local file_path="$1"
    local url="$2"
    local expected_sha="$3"

    # Baixa para temp e faz replace atômico
    local tmp="${file_path}.tmp.$$"
    curl -fsSL -o "$tmp" "$url"
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi

    sha256_check_optional "$tmp" "$expected_sha"

    mv -f "$tmp" "$file_path"
    chmod 0755 "$file_path"
}

init_paths() {
    mkdir -p "$XRAY_DIR" "$SSL_DIR"
    touch "$USER_DB"
    # active_domain pode não existir no começo; não é erro.
    touch "$ACTIVE_DOMAIN_FILE" 2>/dev/null || true
}

validate_domain_basic() {
    # Validação básica: não-vazio e sem espaços
    local d="${1:-}"
    [ -n "$d" ] || return 1
    [[ "$d" =~ ^[^[:space:]]+$ ]] || return 1
    return 0
}

# --- FUNÇÃO AUXILIAR DE DOWNLOAD (CACHE + SAFE) ---
func_download_exec() {
    local file_path="$1"
    local url="$2"
    local description="$3"
    local expected_sha="${4:-}"
    shift 4 || true

    # Só baixa se não existir ou se estiver vazio
    if [ ! -s "$file_path" ]; then
        echo -e "${TXT_YELLOW}Baixando módulo: $description...${RESET}"
        if ! download_file_strict "$file_path" "$url" "$expected_sha"; then
            echo -e "${TXT_RED}Erro ao baixar $description! Verifique conexão/GitHub.${RESET}"
            sleep 2
            return 1
        fi
    else
        # Se existir, ainda vale (opcional) validar hash se esperado foi definido
        if [ -n "$expected_sha" ]; then
            if ! sha256_check_optional "$file_path" "$expected_sha"; then
                echo -e "${TXT_RED}Hash inválido em cache ($description). Rebaixando...${RESET}"
                rm -f "$file_path"
                if ! download_file_strict "$file_path" "$url" "$expected_sha"; then
                    echo -e "${TXT_RED}Erro ao baixar $description.${RESET}"
                    sleep 2
                    return 1
                fi
            fi
        fi
    fi

    bash "$file_path" "$@"
}

# --- SISTEMA ---
func_install_official_core() {
    header_blue "INSTALANDO XRAY CORE"

    ensure_cmd unzip unzip
    ensure_cmd curl curl
    ensure_cmd socat socat

    echo "1. Dependências: OK"
    echo "2. Baixando instalador oficial..."

    rm -f /tmp/install_xray.sh
    curl -fsSL -o /tmp/install_xray.sh "https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

    if [ ! -s "/tmp/install_xray.sh" ]; then
        echo -e "${TXT_RED}Erro: Não foi possível baixar o instalador.${RESET}"
        sleep 3
        return 1
    fi

    echo "3. Executando instalação..."
    chmod 0755 /tmp/install_xray.sh
    bash /tmp/install_xray.sh install
    local ret_val=$?
    rm -f /tmp/install_xray.sh

    echo "------------------------------------------------"
    if [ $ret_val -eq 0 ] && [ -x "/usr/local/bin/xray" ]; then
        echo -e "${TXT_GREEN}SUCESSO! Xray Core instalado.${RESET}"
        sleep 2
        return 0
    else
        echo -e "${TXT_RED}FALHA NA INSTALAÇÃO.${RESET}"
        sleep 5
        return 1
    fi
}

func_call_monitor() {
    func_download_exec "$MONITOR_LOCAL" "$REPO_BASE/onlinexray.sh" "Monitor Online" "$SHA_MONITOR"
}

func_xray_cert() {
    local domain_arg="${1:-}"
    func_download_exec "$CERT_LOCAL" "$REPO_BASE/certxray.sh" "Certificados SSL" "$SHA_CERT" "$domain_arg"
}

func_module_block() {
    func_download_exec "$BLOCK_LOCAL" "$REPO_BASE/block_user.sh" "Bloqueador" "$SHA_BLOCK"
}

func_module_unblock() {
    func_download_exec "$UNBLOCK_LOCAL" "$REPO_BASE/unblock_user.sh" "Desbloqueador" "$SHA_UNBLOCK"
}

func_install_bot() {
    func_download_exec "$BOT_SHELL_LOCAL" "$REPO_BASE/botxray.sh" "Instalador do Bot" "$SHA_BOT"
}

# --- BACKUP ---
func_backup_system() {
    header_blue "SISTEMA DE BACKUP"
    echo "Isso irá salvar:"
    echo " - Banco de Dados"
    echo " - Configs e Certificados"
    echo ""
    echo -e "${TXT_CYAN}[1] CRIAR NOVO BACKUP${RESET}"
    echo -e "${TXT_CYAN}[0] VOLTAR${RESET}"
    echo ""
    read -rp "Opção: " bkp_opt
    if [[ "$bkp_opt" != "1" ]]; then return 0; fi

    local backup_dir="/root/backups"
    local date_now
    date_now=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/backup_dragoncore_${date_now}.tar.gz"
    local filename
    filename=$(basename "$backup_file")

    mkdir -p "$backup_dir"
    echo ""
    echo "Criando backup..."

    if [ ! -f "$USER_DB" ] && [ ! -d "/usr/local/etc/xray" ]; then
        echo -e "${TXT_RED}Erro: Arquivos não encontrados!${RESET}"
        read -rp "Enter..."
        return 1
    fi

    tar -czf "$backup_file" /opt/XrayTools /usr/local/etc/xray >/dev/null 2>&1

    if [ -f "$backup_file" ]; then
        echo ""
        echo "Limpando backups antigos..."
        find "$backup_dir" -name "*.tar.gz" -type f ! -name "$filename" -delete
        echo -e "${TXT_GREEN}BACKUP CRIADO!${RESET}"
        echo -e "Arquivo: ${TXT_CYAN}$filename${RESET}"
    else
        echo -e "${TXT_RED}Falha ao criar backup.${RESET}"
        return 1
    fi
    echo "========================================="
    read -rp "Enter para voltar..."
}

# --- RESTAURAÇÃO ---
func_restore_system() {
    header_red "RESTAURAÇÃO DE SISTEMA"
    local backup_dir="/root/backups"

    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir"/*.tar.gz 2>/dev/null)" ]; then
        echo -e "${TXT_YELLOW}AVISO:${RESET} Nenhum backup encontrado."
        read -rp "Enter para voltar..."
        return 0
    fi

    echo -e "${TXT_YELLOW}ATENÇÃO:${RESET} Substituirá dados atuais."
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
        if [[ "$confirm_auto" != "s" ]]; then return 0; fi
    else
        echo "Backups encontrados:"
        local i=1
        for bkp in "${backups[@]}"; do
            echo -e "${TXT_CYAN}[$i]${RESET} $(basename "$bkp")"
            ((i++))
        done
        echo ""
        read -rp "Escolha o número (0 cancela): " choice
        if [ "$choice" == "0" ] || [ -z "$choice" ]; then return 0; fi
        local index=$((choice - 1))
        selected_file="${backups[$index]}"
    fi

    echo "Restaurando..."
    systemctl stop xray >/dev/null 2>&1 || true
    systemctl stop botxray >/dev/null 2>&1 || true

    tar -tzf "$selected_file" >/dev/null 2>&1
    tar -xzf "$selected_file" -C / >/dev/null 2>&1

    systemctl restart xray >/dev/null 2>&1 || true
    systemctl restart botxray >/dev/null 2>&1 || true
    echo -e "${TXT_GREEN}RESTAURAÇÃO CONCLUÍDA!${RESET}"
    read -rp "Enter para voltar..."
}

# --- GERAÇÃO DE CONFIG (TLS endurecido) ---
func_generate_config() {
    local port="$1"
    local network="$2"
    local domain="$3"
    local api_port="$4"
    local use_tls="$5"

    mkdir -p "$(dirname "$CONFIG_PATH")"
    local stream_settings=""
    local policy='{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}},"system":{"statsInboundUplink":true,"statsInboundDownlink":true}}'

    local routing_rules='[
        {"type":"field","inboundTag":["api"],"outboundTag":"api"},
        {"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},
        {"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}
    ]'

    if [ "$network" == "xhttp" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{
                network:"xhttp",
                security:"tls",
                tlsSettings:{
                    serverName:$dom,
                    certificates:[{certificateFile:$crt, keyFile:$key}],
                    alpn:["h2","http/1.1"],
                    minVersion:"1.2"
                },
                xhttpSettings:{
                    path:"/",
                    scMaxBufferedPosts:30,
                    scMaxEachPostBytes:"1000000",
                    scStreamUpServerSecs:"20-80",
                    xPaddingBytes:"100-1000"
                }
            }')
        else
            stream_settings=$(jq -n \
            '{
                network:"xhttp",
                security:"none",
                xhttpSettings:{
                    path:"/",
                    scMaxBufferedPosts:30,
                    scMaxEachPostBytes:"1000000",
                    scStreamUpServerSecs:"20-80",
                    xPaddingBytes:"100-1000"
                }
            }')
        fi

    elif [ "$network" == "ws" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{
                network:"ws",
                security:"tls",
                tlsSettings:{
                    serverName:$dom,
                    certificates:[{certificateFile:$crt, keyFile:$key}],
                    minVersion:"1.2"
                },
                wsSettings:{acceptProxyProtocol:false, path:"/"}
            }')
        else
            stream_settings=$(jq -n '{network:"ws",security:"none",wsSettings:{acceptProxyProtocol:false,path:"/"}}')
        fi

    elif [ "$network" == "grpc" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{
                network:"grpc",
                security:"tls",
                tlsSettings:{
                    serverName:$dom,
                    certificates:[{certificateFile:$crt, keyFile:$key}],
                    minVersion:"1.2"
                },
                grpcSettings:{serviceName:"gRPC"}
            }')
        else
            stream_settings=$(jq -n '{network:"grpc",security:"none",grpcSettings:{serviceName:"gRPC"}}')
        fi

    elif [ "$network" == "vision" ]; then
        stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
        '{
            network:"tcp",
            security:"tls",
            tlsSettings:{
                serverName:$dom,
                certificates:[{certificateFile:$crt, keyFile:$key}],
                minVersion:"1.2"
            },
            tcpSettings:{header:{type:"none"}}
        }')

    else
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{
                network:"tcp",
                security:"tls",
                tlsSettings:{
                    serverName:$dom,
                    certificates:[{certificateFile:$crt, keyFile:$key}],
                    minVersion:"1.2"
                }
            }')
        else
            stream_settings=$(jq -n '{network:"tcp",security:"none"}')
        fi
    fi

    jq -n \
      --argjson stream "$stream_settings" \
      --arg port "$port" \
      --arg api "$api_port" \
      --argjson pol "$policy" \
      --argjson rules "$routing_rules" \
      '{
        log:{loglevel:"warning"},
        stats:{},
        api:{services:["HandlerService","LoggerService","StatsService"], tag:"api"},
        policy:$pol,
        inbounds:[
          {tag:"api", port:($api|tonumber), protocol:"dokodemo-door", settings:{address:"127.0.0.1"}, listen:"127.0.0.1"},
          {tag:"inbound-dragoncore", port:($port|tonumber), protocol:"vless", settings:{clients:[], decryption:"none", fallbacks:[]}, streamSettings:$stream}
        ],
        outbounds:[
          {protocol:"freedom", tag:"direct"},
          {protocol:"blackhole", tag:"blocked"}
        ],
        routing:{domainStrategy:"AsIs", rules:$rules}
      }' > "$CONFIG_PATH"

    if [ "$network" == "vision" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow":"xtls-rprx-vision"}' \
          "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
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

    systemctl restart xray >/dev/null 2>&1 || true
    sleep 2

    header_blue "INSTALAÇÃO CONCLUÍDA"
    if systemctl is-active --quiet xray; then
        echo -e "STATUS: ${TXT_GREEN}ATIVO${RESET}"
    else
        echo -e "STATUS: ${TXT_RED}FALHA AO INICIAR${RESET}"
        journalctl -u xray -n 5 --no-pager || true
    fi

    local tls_msg="${TXT_RED}DESATIVADO${RESET}"
    if [ "$use_tls" == "true" ]; then tls_msg="${TXT_GREEN}ATIVADO (TLS/SSL)${RESET}"; fi

    echo ""
    echo "========================================="
    echo -e " ${TXT_YELLOW}PROTOCOLO:${RESET}        ${TXT_CYAN}${network^^}${RESET}"
    echo -e " ${TXT_YELLOW}DOMÍNIO (SNI):${RESET}    ${TXT_CYAN}${domain}${RESET}"
    echo -e " ${TXT_YELLOW}PORTA:${RESET}            ${TXT_CYAN}${port}${RESET}"
    echo -e " ${TXT_YELLOW}CRIPTOGRAFIA:${RESET}     ${tls_msg}"
    echo -e " ${TXT_YELLOW}PROTEÇÃO:${RESET}         ${TXT_GREEN}TORRENT & LAN BLOQUEADOS${RESET}"
    echo "========================================="
    echo ""

    local universal_uuid
    universal_uuid=$(uuidgen)

    local link=""
    local sec_param="none"
    if [ "$use_tls" == "true" ]; then sec_param="tls"; fi

    if [ "$network" == "grpc" ]; then
        link="vless://${universal_uuid}@${domain}:${port}?security=${sec_param}&encryption=none&type=grpc&serviceName=gRPC&sni=${domain}#VLESS_BASE"
    elif [ "$network" == "ws" ]; then
        link="vless://${universal_uuid}@${domain}:${port}?path=%2F&security=${sec_param}&encryption=none&host=${domain}&type=ws&sni=${domain}#VLESS_BASE"
    elif [ "$network" == "xhttp" ]; then
        link="vless://${universal_uuid}@${domain}:${port}?mode=auto&path=%2F&security=${sec_param}&encryption=none&host=${domain}&type=xhttp&sni=${domain}#VLESS_BASE"
    elif [ "$network" == "vision" ]; then
        link="vless://${universal_uuid}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#VLESS_BASE"
    else
        link="vless://${universal_uuid}@${domain}:${port}?security=${sec_param}&encryption=none&type=tcp&sni=${domain}#VLESS_BASE"
    fi

    echo -e "${TXT_YELLOW}UUID UNIVERSAL:${RESET}"
    echo -e "${TXT_CYAN}${universal_uuid}${RESET}"
    echo ""
    echo -e "${TXT_YELLOW}LINK VLESS (TEMPLATE):${RESET}"
    echo -e "${TXT_BLUE}${link}${RESET}"
    echo ""
    echo "========================================="
    echo "NOTA: Crie um usuário real na Opção 1."
    echo "========================================="
    read -rp "Enter para finalizar..."
}

func_add_user_logic() {
    local nick="$1"
    local expiry_days="$2"

    if [ -z "$nick" ]; then return 1; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "Erro: config não encontrada."; return 1; fi

    if grep -q "^${nick}|" "$USER_DB"; then
        echo "Erro: usuário já existe no DB."
        return 1
    fi

    local uuid
    uuid=$(uuidgen)
    local expiry
    expiry=$(date -d "+$expiry_days days" +%F)

    jq --arg uuid "$uuid" --arg nick_arg "$nick" \
        '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) += [{"id":$uuid,"email":$nick_arg,"level":0}]' \
        "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    echo "${nick}|${uuid}|${expiry}" >> "$USER_DB"
    systemctl restart xray >/dev/null 2>&1 || true

    clear
    echo -e "${TXT_GREEN}Usuário criado!${RESET}"
    echo "-----------------------------------------"
    echo -e "User: ${TXT_CYAN}${nick}${RESET}"
    echo -e "UUID: ${TXT_YELLOW}${uuid}${RESET}"
    echo -e "Expira: ${expiry}"
    echo "-----------------------------------------"
}

func_remove_user_logic() {
    local identifier="$1"
    if [ -z "$identifier" ]; then return 0; fi
    if [ ! -f "$CONFIG_PATH" ]; then echo "Erro: config não encontrada."; return 1; fi

    jq --arg id "$identifier" \
        '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |= map(select(.id != $id and .email != $id))' \
        "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    if [ -f "$USER_DB" ]; then
        awk -F'|' -v id="$identifier" '($1!=id && $2!=id){print $0}' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
    fi

    systemctl restart xray >/dev/null 2>&1 || true
    echo -e "${TXT_GREEN}Removido.${RESET}"
    sleep 1
}

func_page_create_user() {
    header_blue "CRIAR NOVO USUÁRIO"
    echo "Regras para o nome:"
    echo " - Mínimo 5 e Máximo 9 caracteres"
    echo " - Apenas letras e números"
    echo ""
    read -rp "Nome (0 p/ voltar): " raw_nick
    if [ "$raw_nick" == "0" ] || [ -z "$raw_nick" ]; then return 0; fi

    if ! [[ "$raw_nick" =~ ^[a-zA-Z0-9]{5,9}$ ]]; then
        echo -e "${TXT_RED}Formato inválido.${RESET}"
        read -rp "Enter..."
        return 0
    fi

    if grep -q "^${raw_nick}|" "$USER_DB"; then
        echo -e "${TXT_RED}Usuário já existe!${RESET}"
        sleep 2
        return 0
    fi

    read -rp "Dias de validade (padrão 30): " days
    [ -z "$days" ] && days=30
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then days=30; fi

    func_add_user_logic "$raw_nick" "$days"
    read -rp "Enter para voltar..."
}

func_page_remove_user() {
    header_blue "REMOVER USUÁRIO"
    read -rp "Nome ou UUID: " id_input
    if [ -n "$id_input" ]; then func_remove_user_logic "$id_input"; fi
    read -rp "Enter para voltar..."
}

func_page_list_users() {
    header_blue "LISTA"
    printf "%-15s | %-37s | %s\n" "USER" "UUID" "EXPIRA"
    echo "-----------------------------------------------------------------------"
    if [ -f "$USER_DB" ]; then
        while IFS='|' read -r nick uuid expiry; do
            [ -n "$nick" ] && printf "%-15s | %-37s | %s\n" "$nick" "$uuid" "$expiry"
        done < "$USER_DB"
    else
        echo "Vazio."
    fi
    echo "-----------------------------------------------------------------------"
    read -rp "Enter para voltar..."
}

func_page_purge_expired() {
    header_blue "LIMPEZA DE EXPIRADOS"

    local today
    today=$(date +%F)
    local count=0

    if [ ! -f "$USER_DB" ] || [ ! -s "$USER_DB" ]; then
        echo "Banco de dados vazio."
        read -rp "Enter..."
        return 0
    fi

    echo -e "${TXT_YELLOW}Verificando...${RESET}"
    echo ""
    printf "%-20s | %s\n" "USUÁRIO" "VENCIMENTO"
    echo "-----------------------------------"

    local found=false
    while IFS='|' read -r nick uuid expiry; do
        if [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$expiry" < "$today" ]]; then
            printf "${TXT_RED}%-20s${RESET} | ${TXT_RED}%s${RESET}\n" "$nick" "$expiry"
            found=true
            ((count++))
        fi
    done < "$USER_DB"

    echo "-----------------------------------"
    echo ""

    if [ "$found" = false ]; then
        echo -e "${TXT_GREEN}Nenhum usuário vencido.${RESET}"
        read -rp "Enter..."
        return 0
    fi

    echo -e "Encontrados ${TXT_RED}${count}${RESET} usuários vencidos."
    read -rp "Excluir agora? [s/n]: " confirm
    if [[ "$confirm" != "s" ]]; then
        echo "Cancelado."
        sleep 2
        return 0
    fi

    > "${USER_DB}.tmp"

    while IFS='|' read -r nick uuid expiry; do
        if [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$expiry" < "$today" ]]; then
            echo -e "Removendo: ${TXT_RED}${nick}${RESET}"
            jq --arg id "$uuid" \
              '(.inbounds[] | select(.tag=="inbound-dragoncore").settings.clients) |= map(select(.id != $id))' \
              "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        else
            echo "${nick}|${uuid}|${expiry}" >> "${USER_DB}.tmp"
        fi
    done < "$USER_DB"

    mv "${USER_DB}.tmp" "$USER_DB"
    systemctl restart xray >/dev/null 2>&1 || true

    echo -e "${TXT_GREEN}Limpeza concluída.${RESET}"
    read -rp "Enter para voltar..."
}

func_call_limiter() {
    echo "Verificando limitador..."
    if [ -f "$CONFIG_PATH" ]; then
        if ! grep -q '"stats":' "$CONFIG_PATH"; then
            systemctl stop xray >/dev/null 2>&1 || true
            jq '.stats = {}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            systemctl restart xray >/dev/null 2>&1 || true
        fi
    fi
    func_download_exec "$LIMITER_LOCAL" "$REPO_BASE/limiterxray.sh" "Limitador" "$SHA_LIMITER"
}

func_wizard_install() {
    header_blue "PASSO 1: INSTALAÇÃO DO NÚCLEO"
    echo -e "${TXT_YELLOW}Instalar/atualizar Xray Core agora?${RESET}"
    read -rp "Digite [s] para SIM ou [n] para NÃO: " install_opt
    if [[ "$install_opt" =~ ^[Ss]$ ]]; then func_install_official_core || true; fi

    header_blue "PASSO 2: TLS"
    echo -e "${TXT_YELLOW}Usar TLS/SSL?${RESET}"
    echo " [1] SIM (recomendado)"
    echo " [2] NÃO"
    read -rp "Opção [1-2]: " tls_opt
    local use_tls="false"
    if [ "$tls_opt" == "1" ]; then use_tls="true"; fi

    header_blue "PASSO 3: PORTAS"
    read -rp "Porta Interna (API) [padrão 1080]: " api_port
    [ -z "$api_port" ] && api_port="1080"
    if ! validate_port "$api_port"; then
        echo -e "${TXT_RED}Porta API inválida.${RESET}"
        read -rp "Enter..."
        return 0
    fi

    read -rp "Porta Pública (listen) [padrão 80]: " pub_port
    [ -z "$pub_port" ] && pub_port="80"
    if ! validate_port "$pub_port"; then
        echo -e "${TXT_RED}Porta pública inválida.${RESET}"
        read -rp "Enter..."
        return 0
    fi

    ensure_cmd lsof lsof
    echo "Verificando disponibilidade da porta $pub_port..."
    if lsof -Pi :"$pub_port" -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo -e "${TXT_RED}A porta $pub_port já está em uso.${RESET}"
        lsof -i :"$pub_port" || true
        read -rp "Enter..."
        return 0
    fi

    header_blue "PASSO 4: DOMÍNIO / SNI"
    local domain_val=""

    if [ "$use_tls" == "true" ]; then
        echo -e "${TXT_YELLOW}Digite seu domínio (apontado para este IP):${RESET}"
        read -rp "Domínio: " domain_val

        if ! validate_domain_basic "$domain_val"; then
            echo -e "${TXT_RED}Domínio inválido/vazio. TLS exige domínio válido.${RESET}"
            read -rp "Enter..."
            return 0
        fi

        func_xray_cert "$domain_val" || true
    else
        echo -e "${TXT_YELLOW}Digite domínio ou IP da VPS (vazio = autodetect):${RESET}"
        read -rp "Endereço: " domain_val
        if [ -z "$domain_val" ]; then
            domain_val=$(curl -fsSL icanhazip.com 2>/dev/null || echo "")
        fi
    fi

    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"

    header_blue "PASSO 5: PROTOCOLO"
    echo " [1] WS"
    echo " [2] GRPC"
    echo " [3] XHTTP"
    echo " [4] TCP"
    echo " [5] VISION (TLS TCP + flow)"
    echo " [0] CANCELAR"
    read -rp "Opção [1-5]: " prot_opt

    local selected_net=""
    case "$prot_opt" in
        1) selected_net="ws" ;;
        2) selected_net="grpc" ;;
        3) selected_net="xhttp" ;;
        4) selected_net="tcp" ;;
        5)
            selected_net="vision"
            if [ "$use_tls" == "false" ]; then
                echo -e "${TXT_RED}VISION exige TLS neste modo. Ativando TLS.${RESET}"
                use_tls="true"
                # Se chegou aqui sem domínio, volta (VISION TLS precisa de domínio/cert no seu fluxo atual)
                if ! validate_domain_basic "$domain_val"; then
                    echo -e "${TXT_RED}VISION requer domínio válido neste setup.${RESET}"
                    read -rp "Enter..."
                    return 0
                fi
            fi
            ;;
        0) return 0 ;;
        *) echo "Opção inválida."; sleep 2; return 0 ;;
    esac

    func_generate_config "$pub_port" "$selected_net" "$domain_val" "$api_port" "$use_tls"
}

func_page_uninstall() {
    header_red "DESINSTALAÇÃO E LIMPEZA TOTAL"
    echo -e "${TXT_RED}ATENÇÃO:${RESET} Ação irreversível."
    read -rp "Continuar? [s/n]: " confirm
    if [[ "$confirm" != "s" ]]; then return 0; fi

    local domain_rem=""
    if [ -f "/usr/local/etc/xray/preset.json" ]; then
        domain_rem=$(grep -oP '"domain": "\K[^"]+' /usr/local/etc/xray/preset.json 2>/dev/null || true)
    fi
    if [ -z "$domain_rem" ] && [ -f "$ACTIVE_DOMAIN_FILE" ]; then
        domain_rem=$(cat "$ACTIVE_DOMAIN_FILE" 2>/dev/null || true)
    fi

    echo "Parando serviços..."
    systemctl stop xray >/dev/null 2>&1 || true
    systemctl disable xray >/dev/null 2>&1 || true
    systemctl stop botxray >/dev/null 2>&1 || true
    systemctl disable botxray >/dev/null 2>&1 || true

    echo "Removendo arquivos..."
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/botxray.service
    systemctl daemon-reload >/dev/null 2>&1 || true

    rm -f /usr/local/bin/xray
    rm -rf /usr/local/share/xray /usr/local/etc/xray /var/log/xray
    rm -rf /opt/XrayTools /root/backups /opt/DragonCoreSSL

    rm -f "$LIMITER_LOCAL" "$MONITOR_LOCAL" "$BLOCK_LOCAL" "$UNBLOCK_LOCAL" "$CERT_LOCAL" "$BOT_SHELL_LOCAL"

    if command -v certbot >/dev/null 2>&1; then
        if [ -n "$domain_rem" ]; then
            certbot delete --cert-name "$domain_rem" --non-interactive >/dev/null 2>&1 || true
        fi
    fi

    crontab -l 2>/dev/null | grep -v "limiterxray.sh" | crontab - 2>/dev/null || true
    rm -f /usr/bin/xray-menu

    echo -e "${TXT_GREEN}Desinstalação concluída.${RESET}"
    exit 0
}

# --- MENU PRINCIPAL ---
menu_display() {
    clear
    echo -e "${TITLE_BAR}        DRAGONCORE XRAY MANAGER (V7.4)        ${RESET}"
    echo ""

    local status_txt="${TXT_RED}DESATIVADO${RESET}"
    local proto_info="${TXT_RED}---${RESET}"
    local users_count="0"
    local preset_file="/usr/local/etc/xray/preset.json"
    local port="?"
    local net="?"

    if [ -f "$USER_DB" ]; then
        users_count=$(grep -c '|' "$USER_DB" 2>/dev/null || echo 0)
    fi

    if systemctl is-active --quiet xray; then
        status_txt="${TXT_GREEN}ATIVADO${RESET}"

        if [ -f "$preset_file" ]; then
            net=$(jq -r '.network // empty' "$preset_file" 2>/dev/null || echo "")
            port=$(jq -r '.port // empty' "$preset_file" 2>/dev/null || echo "")
        fi

        if [ -z "${net:-}" ] || [ "$net" == "null" ]; then
            net=$(jq -r '.inbounds[] | select(.tag=="inbound-dragoncore").streamSettings.network // empty' "$CONFIG_PATH" 2>/dev/null || echo "")
        fi
        if [ -z "${port:-}" ] || [ "$port" == "null" ]; then
            port=$(jq -r '.inbounds[] | select(.tag=="inbound-dragoncore").port // empty' "$CONFIG_PATH" 2>/dev/null || echo "")
        fi

        [ -n "${net:-}" ] || net="?"
        [ -n "${port:-}" ] || port="?"

        proto_info="${TXT_CYAN}${net^^}${RESET} (Porta: ${TXT_CYAN}${port}${RESET})"
    fi

    local bot_status="${TXT_RED}DESATIVADO${RESET}"
    if systemctl is-active --quiet botxray 2>/dev/null; then
        bot_status="${TXT_GREEN}ATIVADO${RESET}"
    fi

    local online_count="00"
    local clean_port
    clean_port="$(echo "${port}" | tr -dc '0-9' || true)"
    if command -v ss >/dev/null 2>&1 && [ -n "${clean_port:-}" ] && validate_port "$clean_port"; then
        online_count=$(
            ss -tn state established "sport = :$clean_port" 2>/dev/null \
            | awk 'NR>1 {print $5}' \
            | sed 's/:[^:]*$//' \
            | sort -u \
            | wc -l
        )
        online_count="$(printf "%02d" "${online_count:-0}")"
    fi

    echo "-----------------------------------------"
    echo -e "${TXT_CYAN}XRAY:${RESET}        ${status_txt}"
    echo -e "${TXT_CYAN}USUÁRIOS:${RESET}    ${users_count}"
    echo -e "${TXT_CYAN}IPs ATIVOS:${RESET}  ${online_count}"
    echo -e "${TXT_CYAN}INFO:${RESET}        ${proto_info}"
    echo -e "${TXT_CYAN}BOT XRAY:${RESET}    ${bot_status}"
    echo "-----------------------------------------"
    echo ""
    echo -e "${TXT_CYAN}[01] CRIAR USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[02] REMOVER USUÁRIO${RESET}"
    echo -e "${TXT_CYAN}[03] LISTAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[04] INSTALAR/CONFIGURAR XRAY${RESET}"
    echo -e "${TXT_CYAN}[05] LIMPAR EXPIRADOS${RESET}"
    echo -e "${TXT_CYAN}[06] DESINSTALAR XRAY${RESET}"
    echo -e "${TXT_CYAN}[07] LIMITADOR CONSUMO (GB)${RESET}"
    echo -e "${TXT_CYAN}[08] BOT TELEGRAM${RESET}"
    echo -e "${TXT_CYAN}[09] CRIAR BACKUP${RESET}"
    echo -e "${TXT_CYAN}[10] RESTAURAR BACKUP${RESET}"
    echo -e "${TXT_CYAN}[11] BLOQUEAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[12] DESBLOQUEAR USUÁRIOS${RESET}"
    echo -e "${TXT_CYAN}[13] MONITOR ONLINE${RESET}"
    echo -e "${TXT_CYAN}[00] SAIR${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " choice
}

main_loop() {
    while true; do
        menu_display
        case "${choice:-}" in
            1|01) func_page_create_user ;;
            2|02) func_page_remove_user ;;
            3|03) func_page_list_users ;;
            4|04) func_wizard_install ;;
            5|05) func_page_purge_expired ;;
            6|06) func_page_uninstall ;;
            7|07) func_call_limiter ;;
            8|08) func_install_bot ;;
            9|09) func_backup_system ;;
            10)   func_restore_system ;;
            11)   func_module_block ;;
            12)   func_module_unblock ;;
            13)   func_call_monitor ;;
            0|00) exit 0 ;;
            *)    echo "Opção inválida."; sleep 1 ;;
        esac
    done
}

# --- ENTRYPOINT ---
require_root
init_paths

ensure_cmd curl curl
ensure_cmd jq jq
ensure_cmd bc bc
ensure_cmd uuidgen uuid-runtime
ensure_cmd lsof lsof
# ss é opcional (não crítico para funcionamento do menu)
if ! command -v ss >/dev/null 2>&1; then
    apt_install iproute2 || true
fi

if [ -z "${1:-}" ]; then
    main_loop
else
    if declare -F "$1" >/dev/null 2>&1; then
        "$1" "${@:2}"
    else
        echo -e "${TXT_RED}Comando inválido:${RESET} $1"
        exit 1
    fi
fi
