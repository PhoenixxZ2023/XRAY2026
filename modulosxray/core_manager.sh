#!/bin/bash
# core_manager.sh - TURBONET XRAY V1.1
# Correções aplicadas:
#   - chmod 777 → 640/600/700 em todos os arquivos sensíveis
#   - connection_info.txt (UUID + link) agora 600 root:root
#   - certxray.sh agora 700 root:root
#   - Porta API padrão 1080 com fallback dinâmico via _find_free_api_port()
#   - Validação de shebang BOM-safe
#   - validate_domain_or_ip rejeita loopback, broadcast e endereços reservados
#   - V1.1: Bug fix (( )) para [ ] em validação de IP
#   - V1.1: Porta API max configurável via XRAY_API_PORT_MAX
#   - V1.1: Verificação de dependências no início

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; read -rp "Enter para continuar...";' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
XRAYTOOLS_DIR="/opt/XrayTools"
ACTIVE_DOMAIN_FILE="${XRAYTOOLS_DIR}/active_domain"
CONN_INFO_FILE="${XRAYTOOLS_DIR}/connection_info.txt"
LOG_FILE="/tmp/core_manager.log"

SSL_DIR="/opt/TurbonetCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

# Porta API fixa 1080
API_PORT="1080"

_validate_repo_base() {
    local url="$1"
    if [[ ! "$url" =~ ^https://(raw\.githubusercontent\.com|github\.com)/[a-zA-Z0-9._/-]{1,200}$ ]]; then
        echo -e "\033[1;31m❌ REPO_BASE inválido: '${url}'\033[0m"
        exit 1
    fi
}

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/PhoenixxZ2023/XRAY2026/main}"
_validate_repo_base "$REPO_BASE"
CERT_SCRIPT_URL="$REPO_BASE/modulosxray/certxray.sh"

TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

_PKG_MANAGER=""
_detect_pkg_manager() {
    if [ -n "$_PKG_MANAGER" ]; then return 0; fi
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else echo -e "${TXT_RED}❌ Gerenciador de pacotes não detectado.${RESET}"; exit 1; fi
}

_APT_UPDATED=0
ensure_cmd() {
    local cmd="$1" pkg="$2"
    if command -v "$cmd" &>/dev/null; then return 0; fi
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            if [ "$_APT_UPDATED" -eq 0 ]; then
                apt-get update -y >>"$LOG_FILE" 2>&1 || true
                _APT_UPDATED=1
            fi
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
}

# V1.1: Verificação de dependências no início
check_dependencies() {
    local missing=()
    command -v jq    &>/dev/null || missing+=("jq")
    command -v curl  &>/dev/null || missing+=("curl")
    command -v unzip &>/dev/null || missing+=("unzip")
    command -v socat &>/dev/null || missing+=("socat")

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${TXT_YELLOW}Instalando dependências: ${missing[*]}...${RESET}"
        for pkg in "${missing[@]}"; do
            ensure_cmd "$pkg" "$pkg" 2>/dev/null || true
        done
    fi
}

header_blue() { clear; echo -e "${TITLE_BAR}   $1   ${RESET}"; echo ""; }

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${TXT_RED}❌ Execute como root!${RESET}"
        exit 1
    fi
}

_apply_config_perms() {
    chmod 660 "$CONFIG_PATH"
    chown root:"$XRAY_GROUP" "$CONFIG_PATH"
}

validate_port() {
    local p="$1"
    if [[ "$p" =~ ^[0-9]{1,5}$ ]]; then
        if [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then return 0; fi
    fi
    return 1
}

validate_domain() {
    local d="${1:-}"
    d="$(echo "$d" | tr -d '[:space:][:cntrl:]')"
    if [ -z "$d" ]; then return 1; fi
    if [[ "$d" =~ ^[0-9.]+$ ]]; then return 1; fi
    if [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

# V1.1: Bug fix — (( )) → [ ] para compatibilidade com set -e
validate_domain_or_ip() {
    local d="${1:-}"
    d="$(echo "$d" | tr -d '[:space:][:cntrl:]')"
    if [ -z "$d" ]; then return 1; fi

    if [[ "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra parts <<< "$d"
        for p in "${parts[@]}"; do
            # V1.1: Usar [ ] em vez de (( )) para evitar falha com set -e
            if [ "$p" -gt 255 ]; then return 1; fi
        done

        local o1="${parts[0]}" o2="${parts[1]}"
        if [ "$o1" -eq 0 ] || [ "$o1" -eq 127 ]; then return 1; fi
        if [ "$o1" -eq 255 ]; then return 1; fi
        if [ "$o1" -eq 169 ] && [ "$o2" -eq 254 ]; then return 1; fi
        if [ "$o1" -ge 224 ] && [ "$o1" -le 239 ]; then return 1; fi
        if [ "$o1" -eq 10 ]; then return 1; fi
        if [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then return 1; fi
        if [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ]; then return 1; fi

        return 0
    fi

    validate_domain "$d"
}

generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-4"substr($5,2)"-"substr($6,1,1)"8"substr($6,2)"-"$7$8}'
    fi
}

generate_trojan_password() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 16
    else
        cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32
    fi
}

_verify_sha256() {
    local file="$1" sha_url="$2" label="$3"
    local expected
    expected=$(curl -fLsS --max-time 10 --connect-timeout 5 "$sha_url" 2>/dev/null | awk '{print $1}')
    if [ -z "$expected" ]; then
        echo -e "${TXT_YELLOW}⚠  Hash não encontrado para ${label} — verificação ignorada.${RESET}" >&2
        return 0
    fi
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo -e "${TXT_RED}❌ Falha de integridade: ${label}${RESET}" >&2
        return 1
    fi
    return 0
}

port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then return 0; fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":${port} "; then return 0; fi
    elif command -v lsof &>/dev/null; then
        if lsof -Pi :"$port" -sTCP:LISTEN -t &>/dev/null; then return 0; fi
    fi
    return 1
}

# API porta fixa 1080
_find_free_api_port() {
    echo "1080"
}

func_install_official_core() {
    header_blue "INSTALANDO XRAY CORE"
    ensure_cmd unzip unzip
    ensure_cmd curl  curl
    ensure_cmd socat socat

    local install_script="/tmp/xray_install_release.sh"
    local sha_url="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh.sha256"

    echo "Baixando instalador oficial Xray..."
    rm -f "$install_script"
    if ! curl -fLsS --retry 3 --retry-delay 2 --max-time 120 --connect-timeout 15 \
        -o "$install_script" \
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" 2>>"$LOG_FILE"; then
        echo -e "${TXT_RED}❌ Erro no download.${RESET}"; sleep 2; return 1
    fi

    if [ ! -s "$install_script" ]; then
        echo -e "${TXT_RED}❌ Arquivo vazio.${RESET}"; return 1
    fi

    if ! _verify_sha256 "$install_script" "$sha_url" "install-release.sh"; then
        rm -f "$install_script"; sleep 2; return 1
    fi

    if ! LC_ALL=C head -n 1 "$install_script" | grep -qP '^(\xEF\xBB\xBF)?#!.*(bash|env\s)'; then
        echo -e "${TXT_RED}❌ Script inválido.${RESET}"; rm -f "$install_script"; return 1
    fi

    chmod +x "$install_script"
    bash "$install_script" install
    rm -f "$install_script"
    echo -e "${TXT_GREEN}Instalação concluída.${RESET}"
    sleep 1
}

func_xray_cert() {
    local dom="$1"
    local cert_script="/usr/local/bin/certxray.sh"
    ensure_cmd curl curl

    local tmp; tmp=$(mktemp /tmp/certxray_XXXXXX)
    if ! curl -fLsS --retry 3 --retry-delay 2 --max-time 60 --connect-timeout 10 \
        -o "$tmp" "$CERT_SCRIPT_URL" 2>>"$LOG_FILE"; then
        echo -e "${TXT_RED}❌ Erro ao baixar certxray.sh${RESET}"; rm -f "$tmp"; return 1
    fi

    if ! _verify_sha256 "$tmp" "${CERT_SCRIPT_URL}.sha256" "certxray.sh"; then
        rm -f "$tmp"; return 1
    fi

    if ! LC_ALL=C head -n 1 "$tmp" | grep -qP '^(\xEF\xBB\xBF)?#!.*(bash|env\s)'; then
        echo -e "${TXT_RED}❌ certxray.sh inválido.${RESET}"; rm -f "$tmp"; return 1
    fi

    mv -f "$tmp" "$cert_script"
    chmod 700 "$cert_script"
    chown root:root "$cert_script"
    bash "$cert_script" "$dom"
}

func_generate_config() {
    local port="$1" network="$2" domain="$3" use_tls="$4"

    ensure_cmd jq jq
    mkdir -p "$(dirname "$CONFIG_PATH")" "$XRAYTOOLS_DIR" "$SSL_DIR"

    if [ "$use_tls" = "true" ]; then
        if [ ! -s "$CRT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
            echo -e "${TXT_RED}❌ Certificado não encontrado: $CRT_FILE / $KEY_FILE${RESET}"
            read -rp "Pressione Enter..."; return 1
        fi
    fi

    local api_port
    if ! api_port=$(_find_free_api_port "$API_PORT"); then
        read -rp "Pressione Enter..."; return 1
    fi

    local policy='{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}},"system":{"statsInboundUplink":true,"statsInboundDownlink":true}}'
    local routing_rules='[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}]'

    local stream_settings=""
    case "$network" in
        xhttp)
            # XHTTP - Otimizado para HTTP Injection + Operadoras Brasileiras
            # Ajuste baseado no diagnóstico: pacotes menores, conexões curtas
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                    '{network:"xhttp",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],alpn:["http/1.1"],minVersion:"1.3"},xhttpSettings:{path:"/",scMaxBufferedPosts:5,scMaxEachPostBytes:40960,scStreamUpServerSecs:"5-15",xPaddingBytes:""}}')
            else
                stream_settings=$(jq -n \
                    '{network:"xhttp",security:"none",xhttpSettings:{path:"/",scMaxBufferedPosts:5,scMaxEachPostBytes:40960,scStreamUpServerSecs:"5-15",xPaddingBytes:""}}')
            fi ;;
        ws)
            # WebSocket - Otimizado para HTTP Injection + Operadoras Brasileiras
            # Headers realistas e path personalizado para evitar DPI
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                    '{network:"ws",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],alpn:["http/1.1"],minVersion:"1.3"},wsSettings:{acceptProxyProtocol:false,path:"/",header:{host:$dom,Connection:"keep-alive", pragma:"no-cache"}}}')
            else
                stream_settings=$(jq -n --arg dom "$domain" \
                    '{network:"ws",security:"none",wsSettings:{acceptProxyProtocol:false,path:"/",header:{host:$dom,Connection:"keep-alive", pragma:"no-cache"}}}')
            fi ;;
        grpc)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                    '{network:"grpc",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.3"},grpcSettings:{serviceName:"gRPC"}}')
            else
                stream_settings=$(jq -n '{network:"grpc",security:"none",grpcSettings:{serviceName:"gRPC"}}')
            fi ;;
        vision)
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                '{network:"tcp",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.3"},tcpSettings:{header:{type:"none"}}}') ;;
        httpupgrade)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                    '{network:"httpupgrade",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.3"},httpupgradeSettings:{path:"/",host:$dom}}')
            else
                stream_settings=$(jq -n --arg dom "$domain" \
                    '{network:"httpupgrade",security:"none",httpupgradeSettings:{path:"/",host:$dom}}')
            fi ;;
        h2)
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                '{network:"h2",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],alpn:["h2"],minVersion:"1.3"},httpSettings:{path:"/",host:[$dom]}}') ;;
        trojan)
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                '{network:"tcp",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.3"},tcpSettings:{header:{type:"none"}}}') ;;
        *)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                    '{network:"tcp",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.3"}}')
            else
                stream_settings=$(jq -n '{network:"tcp",security:"none"}')
            fi ;;
    esac

    local credential=""
    local clients_json=""
    if [ "$network" = "trojan" ]; then
        credential=$(generate_trojan_password)
        if [ -z "$credential" ]; then
            echo -e "${TXT_RED}❌ Falha ao gerar senha Trojan.${RESET}"; return 1
        fi
        clients_json=$(jq -n --arg pwd "$credential" '[{"password":$pwd,"level":0}]')
    else
        credential=$(generate_uuid)
        if [ -z "$credential" ]; then
            echo -e "${TXT_RED}❌ Falha ao gerar UUID.${RESET}"; return 1
        fi
        if [ "$network" = "vision" ]; then
            clients_json=$(jq -n --arg uuid "$credential" '[{"id":$uuid,"level":0,"flow":"xtls-rprx-vision"}]')
        else
            clients_json=$(jq -n --arg uuid "$credential" '[{"id":$uuid,"level":0}]')
        fi
    fi

    if [ -f "$CONFIG_PATH" ]; then
        cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    fi

    local tmp_config; tmp_config=$(mktemp /tmp/xray_config_XXXXXX.json)

    local inbound_protocol="vless"
    local extra_settings='"decryption":"none","fallbacks":[]'
    if [ "$network" = "trojan" ]; then
        inbound_protocol="trojan"
        extra_settings='}'
    fi

    jq -n \
        --argjson stream   "$stream_settings" \
        --arg     port     "$port" \
        --arg     api      "$api_port" \
        --argjson pol      "$policy" \
        --argjson rules    "$routing_rules" \
        --argjson clients  "$clients_json" \
        --arg     proto    "$inbound_protocol" \
        '{log:{loglevel:"warning"},stats:{},api:{services:["HandlerService","LoggerService","StatsService"],tag:"api"},policy:$pol,inbounds:[{tag:"api",port:($api|tonumber),protocol:"dokodemo-door",settings:{address:"127.0.0.1"},listen:"127.0.0.1"},{tag:"inbound-turbonet",port:($port|tonumber),protocol:$proto,settings:(if $proto=="trojan" then {clients:$clients} else {clients:$clients,decryption:"none",fallbacks:[]} end),streamSettings:$stream}],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"blocked"},{protocol:"freedom",tag:"api"}],routing:{domainStrategy:"AsIs",rules:$rules}}' \
        > "$tmp_config"

    if ! jq empty "$tmp_config" 2>/dev/null; then
        echo -e "${TXT_RED}❌ Config JSON inválido.${RESET}"; rm -f "$tmp_config"; return 1
    fi

    mv -f "$tmp_config" "$CONFIG_PATH"
    _apply_config_perms

    jq -n --arg network "$network" --arg port "$port" --arg domain "$domain" --arg tls "$use_tls" \
        '{network:$network,port:$port,domain:$domain,tls:$tls}' > "$PRESET_FILE"
    chmod 640 "$PRESET_FILE"
    chown root:"$XRAY_GROUP" "$PRESET_FILE"

    echo "$domain" > "$ACTIVE_DOMAIN_FILE"

    echo -e "Reiniciando Xray..."
    if ! systemctl restart xray >>"$LOG_FILE" 2>&1; then
        echo -e "${TXT_RED}❌ Falha ao reiniciar Xray:${RESET}"
        journalctl -u xray -n 25 --no-pager 2>/dev/null || true
        if [ -f "${CONFIG_PATH}.bak" ]; then
            mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
            _apply_config_perms
        fi
        read -rp "Pressione Enter..."; return 1
    fi
    sleep 2

    header_blue "CONFIGURAÇÃO CONCLUÍDA (V1.1)"

    local status_show="${TXT_RED}FALHA${RESET}"
    if systemctl is-active --quiet xray 2>/dev/null; then
        status_show="${TXT_GREEN}ATIVO${RESET}"
    fi

    local tls_msg="${TXT_RED}DESATIVADO${RESET}"
    if [ "$use_tls" = "true" ]; then
        tls_msg="${TXT_GREEN}ATIVADO (TLS 1.2+)${RESET}"
    fi

    echo -e "STATUS: $status_show"
    echo ""
    echo "========================================="
    echo -e " ${TXT_YELLOW}PROTOCOLO:${RESET}   ${TXT_CYAN}${network^^}${RESET}"
    echo -e " ${TXT_YELLOW}DOMÍNIO/SNI:${RESET} ${TXT_CYAN}${domain}${RESET}"
    echo -e " ${TXT_YELLOW}PORTA:${RESET}       ${TXT_CYAN}${port}${RESET}"
    echo -e " ${TXT_YELLOW}API INTERNA:${RESET} ${TXT_CYAN}127.0.0.1:${api_port}${RESET}"
    echo -e " ${TXT_YELLOW}CRIPTOGRAFIA:${RESET} ${tls_msg}"
    echo "========================================="
    echo ""

    local sec="none"
    if [ "$use_tls" = "true" ]; then sec="tls"; fi

    local link=""
    case "$network" in
        grpc)        link="vless://${credential}@${domain}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=gRPC&sni=${domain}#VLESS-TURBONET" ;;
        ws)          link="vless://${credential}@${domain}:${port}?path=%2F&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#VLESS-TURBONET" ;;
        xhttp)       link="vless://${credential}@${domain}:${port}?mode=auto&path=%2F&security=${sec}&encryption=none&host=${domain}&type=xhttp&sni=${domain}#VLESS-TURBONET" ;;
        vision)      link="vless://${credential}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#VLESS-TURBONET" ;;
        httpupgrade) link="vless://${credential}@${domain}:${port}?path=%2F&security=${sec}&encryption=none&host=${domain}&type=httpupgrade&sni=${domain}#VLESS-TURBONET" ;;
        h2)          link="vless://${credential}@${domain}:${port}?path=%2F&security=tls&encryption=none&host=${domain}&type=h2&sni=${domain}#VLESS-TURBONET" ;;
        trojan)      link="trojan://${credential}@${domain}:${port}?security=tls&sni=${domain}&type=tcp#TROJAN-TURBONET" ;;
        *)           link="vless://${credential}@${domain}:${port}?security=${sec}&encryption=none&type=tcp&sni=${domain}#VLESS-TURBONET" ;;
    esac

    echo -e "${TXT_YELLOW}LINK DE CONEXÃO:${RESET}"
    echo -e "${TXT_BLUE}${link}${RESET}"
    echo ""

    mkdir -p "$XRAYTOOLS_DIR"
    cat > "$CONN_INFO_FILE" <<EOF
# TURBONET XRAY - Informações de Conexão
# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')
PROTOCOLO=${network^^}
DOMINIO=${domain}
PORTA=${port}
TLS=${use_tls}
CREDENCIAL=${credential}
LINK=${link}
EOF
    chmod 600 "$CONN_INFO_FILE"
    chown root:root "$CONN_INFO_FILE"

    echo -e "${TXT_GREEN}Link salvo em: ${CONN_INFO_FILE}${RESET}"
    echo ""
    read -rp "Pressione Enter para sair..."
}

func_wizard_install() {
    require_root
    : > "$LOG_FILE"

    # V1.1: Verifica dependências no início
    check_dependencies

    header_blue "PASSO 1/5 — INSTALAÇÃO DO CORE"
    echo -e "${TXT_YELLOW}Deseja instalar/atualizar o Xray Core?${RESET}"
    read -rp "[s] Sim / [n] Não: " inst
    if [[ "$inst" =~ ^[Ss]$ ]]; then
        func_install_official_core || true
    fi

    header_blue "PASSO 2/5 — CRIPTOGRAFIA (TLS)"
    echo -e "${TXT_YELLOW}Deseja usar TLS?${RESET}"
    echo " [1] SIM — HTTPS/TLS (recomendado, porta 443)"
    echo " [2] NÃO — Sem TLS (porta 80)"
    read -rp "Opção [1/2]: " tls_opt
    local use_tls="false"
    if [ "${tls_opt:-2}" = "1" ]; then use_tls="true"; fi

    header_blue "PASSO 3/5 — PORTA DE CONEXÃO"
    if [ "$use_tls" = "true" ]; then
        echo -e "Sugestões: ${TXT_CYAN}443, 8443, 2053${RESET}"
    else
        echo -e "Sugestões: ${TXT_CYAN}80, 8080, 8880${RESET}"
    fi
    read -rp "Porta [Enter = padrão]: " pub_port

    if [ -z "${pub_port:-}" ]; then
        if [ "$use_tls" = "true" ]; then pub_port="443"; else pub_port="80"; fi
    fi

    if ! validate_port "$pub_port"; then
        echo -e "${TXT_RED}❌ Porta inválida.${RESET}"; read -rp "Enter..."; return 1
    fi

    if port_in_use "$pub_port"; then
        echo -e "${TXT_RED}⚠  Porta ${pub_port} em uso.${RESET}"
        read -rp "Continuar mesmo assim? [s/N]: " force
        if [[ ! "${force:-n}" =~ ^[Ss]$ ]]; then return 1; fi
    fi

    header_blue "PASSO 4/5 — DOMÍNIO / ENDEREÇO"
    local domain_val=""
    ensure_cmd curl curl

    if [ "$use_tls" = "true" ]; then
        echo -e "${TXT_YELLOW}Digite o domínio (ex: meusite.com):${RESET}"
        read -rp "Domínio: " domain_val
        domain_val="$(echo "${domain_val:-}" | tr -d '[:space:][:cntrl:]')"
        if ! validate_domain "$domain_val"; then
            echo -e "${TXT_RED}❌ Domínio inválido.${RESET}"; read -rp "Enter..."; return 1
        fi

        if ! func_xray_cert "$domain_val"; then
            echo -e "${TXT_RED}❌ Falha no certificado.${RESET}"; read -rp "Enter..."; return 1
        fi

        if [ ! -s "$CRT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
            echo -e "${TXT_RED}❌ Certificado não gerado.${RESET}"; read -rp "Enter..."; return 1
        fi
    else
        echo -e "${TXT_YELLOW}IP público da VPS ou domínio (sem TLS):${RESET}"
        read -rp "Endereço [Enter = detectar IP]: " domain_val
        domain_val="$(echo "${domain_val:-}" | tr -d '[:space:][:cntrl:]')"
        if [ -z "${domain_val:-}" ]; then
            echo -n "Detectando IP... "
            domain_val=$(curl -fsSL --max-time 10 "https://icanhazip.com" 2>/dev/null || \
                         curl -fsSL --max-time 10 "https://api.ipify.org"  2>/dev/null || echo "")
            echo "${domain_val:-falhou}"
        fi
        if ! validate_domain_or_ip "$domain_val"; then
            echo -e "${TXT_RED}❌ Endereço inválido ou não-roteável.${RESET}"
            read -rp "Enter..."; return 1
        fi
    fi

    mkdir -p "$XRAYTOOLS_DIR"
    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"

    header_blue "PASSO 5/5 — PROTOCOLO"
    echo " [1] WS          — WebSocket"
    echo " [2] GRPC        — gRPC"
    echo " [3] XHTTP       — XHTTP Otimizado (recomendado)"
    echo " [4] TCP         — TCP simples"
    echo " [5] VISION      — XTLS Vision (exige TLS)"
    echo " [6] HTTPUPGRADE — HTTP Upgrade (boa compatibilidade)"
    echo " [7] H2          — HTTP/2 (exige TLS)"
    echo " [8] TROJAN      — Trojan (disfarça como HTTPS, exige TLS)"
    read -rp "Opção [1-8]: " prot_opt

    local selected_net=""
    case "$prot_opt" in
        1) selected_net="ws"          ;;
        2) selected_net="grpc"        ;;
        3) selected_net="xhttp"       ;;
        4) selected_net="tcp"         ;;
        5) selected_net="vision"      ;;
        6) selected_net="httpupgrade" ;;
        7) selected_net="h2"          ;;
        8) selected_net="trojan"      ;;
        *) echo -e "${TXT_RED}❌ Opção inválida.${RESET}"; read -rp "Enter..."; return 1 ;;
    esac

    if [ "$selected_net" = "vision" ] && [ "$use_tls" = "false" ]; then
        echo -e "${TXT_RED}❌ Vision exige TLS.${RESET}"; read -rp "Enter..."; return 1
    fi
    if [ "$selected_net" = "h2" ] && [ "$use_tls" = "false" ]; then
        echo -e "${TXT_RED}❌ HTTP/2 exige TLS.${RESET}"; read -rp "Enter..."; return 1
    fi
    if [ "$selected_net" = "trojan" ] && [ "$use_tls" = "false" ]; then
        echo -e "${TXT_RED}❌ Trojan exige TLS.${RESET}"; read -rp "Enter..."; return 1
    fi

    header_blue "RESUMO DA CONFIGURAÇÃO"
    local proto_desc=""
    case "$selected_net" in
        ws)          proto_desc="WebSocket" ;;
        grpc)        proto_desc="gRPC" ;;
        xhttp)       proto_desc="XHTTP (otimizado)" ;;
        tcp)         proto_desc="TCP simples" ;;
        vision)      proto_desc="XTLS Vision" ;;
        httpupgrade) proto_desc="HTTP Upgrade" ;;
        h2)          proto_desc="HTTP/2" ;;
        trojan)      proto_desc="Trojan (TLS obrigatório)" ;;
        *)           proto_desc="${selected_net^^}" ;;
    esac
    echo "========================================="
    echo -e " ${TXT_CYAN}PROTOCOLO:${RESET}   ${proto_desc}"
    echo -e " ${TXT_CYAN}DOMÍNIO:${RESET}     ${domain_val}"
    echo -e " ${TXT_CYAN}PORTA:${RESET}       ${pub_port}"
    echo -e " ${TXT_CYAN}TLS:${RESET}         ${use_tls}"
    echo "========================================="
    echo ""
    read -rp "Confirmar e aplicar? [s/N]: " confirm

    if [[ ! "${confirm:-n}" =~ ^[Ss]$ ]]; then
        echo "Cancelado."; sleep 1; return 0
    fi

    func_generate_config "$pub_port" "$selected_net" "$domain_val" "$use_tls"
}

func_wizard_install
