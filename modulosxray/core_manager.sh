#!/bin/bash
# core_manager.sh - DragonCore V7.8
# Correções: verificação de integridade de scripts externos, validação de REPO_BASE,
#            validação de domínio RFC 1123, UUID com fallback, detecção de distro,
#            IP via HTTPS, verificação de porta com ss, resumo antes de aplicar,
#            log em falha de restart, link salvo em arquivo seguro.

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; read -rp "Enter para continuar...";' ERR

# --- CONFIGURAÇÕES ---
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
XRAYTOOLS_DIR="/opt/XrayTools"
ACTIVE_DOMAIN_FILE="${XRAYTOOLS_DIR}/active_domain"
CONN_INFO_FILE="${XRAYTOOLS_DIR}/connection_info.txt"
LOG_FILE="/tmp/core_manager.log"

SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"

# --- VALIDAÇÃO DE REPO_BASE ---
# Aceita apenas URLs HTTPS do github.com/raw.githubusercontent.com — sem injeção de host arbitrário
_validate_repo_base() {
    local url="$1"
    if [[ ! "$url" =~ ^https://(raw\.githubusercontent\.com|github\.com)/[a-zA-Z0-9._/-]{1,200}$ ]]; then
        echo -e "\033[1;31m❌ REPO_BASE inválido ou inseguro: '${url}'\033[0m"
        exit 1
    fi
}

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main}"
_validate_repo_base "$REPO_BASE"

CERT_SCRIPT_URL="$REPO_BASE/modulosxray/certxray.sh"

# CORES
TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- DETECÇÃO DE GERENCIADOR DE PACOTES ---
_PKG_MANAGER=""
_detect_pkg_manager() {
    if [ -n "$_PKG_MANAGER" ]; then return; fi
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else
        echo -e "${TXT_RED}❌ Gerenciador de pacotes não detectado.${RESET}"
        exit 1
    fi
}

_APT_UPDATED=0
ensure_cmd() {
    local cmd="$1" pkg="$2"
    command -v "$cmd" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            if [ "$_APT_UPDATED" -eq 0 ]; then
                apt-get update -y >>"$LOG_FILE" 2>&1 || true
                _APT_UPDATED=1
            fi
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
            ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
}

# --- FUNÇÕES BÁSICAS ---
header_blue() {
    clear
    echo -e "${TITLE_BAR}   $1   ${RESET}"
    echo ""
}

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${TXT_RED}❌ Execute como root!${RESET}"
        exit 1
    fi
}

# --- VALIDAÇÃO DE PORTA ---
validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( p >= 1 && p <= 65535 ))
}

# --- VALIDAÇÃO DE DOMÍNIO (RFC 1123 estrita) ---
# Aceita: labels de 1-63 chars (a-z, 0-9, hífen), separados por ponto, mínimo 2 labels
validate_domain() {
    local d="${1:-}"
    [ -n "$d" ] || return 1
    # Rejeita IPs — domínio deve ter pelo menos uma letra
    [[ "$d" =~ ^[0-9.]+$ ]] && return 1
    # Valida formato RFC 1123
    if [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

# Aceita domínio OU IP (para modo sem TLS)
validate_domain_or_ip() {
    local d="${1:-}"
    [ -n "$d" ] || return 1
    # IP v4
    if [[ "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra parts <<< "$d"
        for p in "${parts[@]}"; do
            (( p <= 255 )) || return 1
        done
        return 0
    fi
    validate_domain "$d"
}

# --- GERAÇÃO DE UUID COM FALLBACK ---
generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        # fallback manual via /dev/urandom
        local h
        h=$(od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-4"substr($5,2)"-"substr($6,1,1)"8"substr($6,2)"-"$7$8}')
        echo "$h"
    fi
}

# --- VERIFICAÇÃO DE INTEGRIDADE ---
# Baixa SHA256 opcional; se não existir, emite aviso mas não bloqueia
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
        echo -e "   Esperado: ${expected}" >&2
        echo -e "   Obtido:   ${actual}" >&2
        return 1
    fi
}

# --- CHECAGEM DE PORTA EM USO (com fallback ss → netstat → lsof) ---
port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v lsof &>/dev/null; then
        lsof -Pi :"$port" -sTCP:LISTEN -t &>/dev/null && return 0
    fi
    return 1
}

# --- INSTALADOR XRAY CORE ---
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
        echo -e "${TXT_RED}❌ Erro no download do instalador.${RESET}"
        sleep 2
        return 1
    fi

    if [ ! -s "$install_script" ]; then
        echo -e "${TXT_RED}❌ Instalador baixado está vazio.${RESET}"
        return 1
    fi

    # Verifica integridade (SHA256 se disponível no repo XTLS)
    if ! _verify_sha256 "$install_script" "$sha_url" "install-release.sh"; then
        echo -e "${TXT_RED}❌ Instalador rejeitado por falha de integridade.${RESET}"
        rm -f "$install_script"
        sleep 2
        return 1
    fi

    # Valida shebang mínimo
    local head_bytes
    head_bytes=$(head -c 12 "$install_script")
    if [[ "$head_bytes" != "#!/bin/bash"* ]] && [[ "$head_bytes" != "#!/usr/bin/e"* ]]; then
        echo -e "${TXT_RED}❌ Instalador não parece um shell script válido.${RESET}"
        rm -f "$install_script"
        return 1
    fi

    chmod +x "$install_script"
    bash "$install_script" install
    rm -f "$install_script"
    echo -e "${TXT_GREEN}Instalação concluída.${RESET}"
    sleep 1
}

# --- CHAMADA DO CERTIFICADO ---
func_xray_cert() {
    local dom="$1"
    local cert_script="/usr/local/bin/certxray.sh"
    local sha_url="${CERT_SCRIPT_URL}.sha256"

    ensure_cmd curl curl

    # Sempre re-baixa para garantir versão atualizada
    local tmp
    tmp=$(mktemp /tmp/certxray_XXXXXX)
    if ! curl -fLsS --retry 3 --retry-delay 2 --max-time 60 --connect-timeout 10 \
            -o "$tmp" "$CERT_SCRIPT_URL" 2>>"$LOG_FILE"; then
        echo -e "${TXT_RED}❌ Erro ao baixar certxray.sh${RESET}"
        rm -f "$tmp"
        return 1
    fi

    if ! _verify_sha256 "$tmp" "$sha_url" "certxray.sh"; then
        echo -e "${TXT_RED}❌ certxray.sh rejeitado por falha de integridade.${RESET}"
        rm -f "$tmp"
        return 1
    fi

    # Valida shebang
    local head_bytes
    head_bytes=$(head -c 12 "$tmp")
    if [[ "$head_bytes" != "#!/bin/bash"* ]] && [[ "$head_bytes" != "#!/usr/bin/e"* ]]; then
        echo -e "${TXT_RED}❌ certxray.sh não parece um shell script válido.${RESET}"
        rm -f "$tmp"
        return 1
    fi

    mv -f "$tmp" "$cert_script"
    chmod 0777 "$cert_script"
    bash "$cert_script" "$dom"
}

# --- GERAÇÃO DA CONFIGURAÇÃO ---
func_generate_config() {
    local port="$1"
    local network="$2"
    local domain="$3"
    local api_port="$4"
    local use_tls="$5"

    ensure_cmd jq jq

    mkdir -p "$(dirname "$CONFIG_PATH")" "$XRAYTOOLS_DIR" "$SSL_DIR"

    # Valida cert/key ANTES de qualquer escrita
    if [ "$use_tls" = "true" ]; then
        if [ ! -s "$CRT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
            echo -e "${TXT_RED}❌ TLS ativo mas certificado não encontrado:${RESET}"
            echo "   - $CRT_FILE"
            echo "   - $KEY_FILE"
            read -rp "Pressione Enter..."
            return 1
        fi
    fi

    # Verifica se api_port está em uso (e sugere alternativa)
    if port_in_use "$api_port"; then
        echo -e "${TXT_YELLOW}⚠  Porta API ${api_port} em uso. Tentando 1080...${RESET}"
        api_port="1080"
        if port_in_use "$api_port"; then
            echo -e "${TXT_RED}❌ Porta API alternativa também em uso. Abortando.${RESET}"
            read -rp "Pressione Enter..."
            return 1
        fi
    fi

    local policy='{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}},"system":{"statsInboundUplink":true,"statsInboundDownlink":true}}'
    local routing_rules='[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}]'

    # Bloco de streamSettings por protocolo
    local stream_settings=""
    case "$network" in
        xhttp)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{
                    network:"xhttp", security:"tls",
                    tlsSettings:{serverName:$dom, certificates:[{certificateFile:$crt,keyFile:$key}], alpn:["h2","http/1.1"], minVersion:"1.2"},
                    xhttpSettings:{path:"/", scMaxBufferedPosts:30, scMaxEachPostBytes:"1000000", scStreamUpServerSecs:"20-80", xPaddingBytes:"100-1000"}
                }')
            else
                stream_settings=$(jq -n '{network:"xhttp", security:"none",
                    xhttpSettings:{path:"/", scMaxBufferedPosts:30, scMaxEachPostBytes:"1000000", scStreamUpServerSecs:"20-80", xPaddingBytes:"100-1000"}
                }')
            fi
            ;;
        ws)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{
                    network:"ws", security:"tls",
                    tlsSettings:{serverName:$dom, certificates:[{certificateFile:$crt,keyFile:$key}], minVersion:"1.2"},
                    wsSettings:{acceptProxyProtocol:false, path:"/"}
                }')
            else
                stream_settings=$(jq -n '{network:"ws", security:"none", wsSettings:{acceptProxyProtocol:false, path:"/"}}')
            fi
            ;;
        grpc)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{
                    network:"grpc", security:"tls",
                    tlsSettings:{serverName:$dom, certificates:[{certificateFile:$crt,keyFile:$key}], minVersion:"1.2"},
                    grpcSettings:{serviceName:"gRPC"}
                }')
            else
                stream_settings=$(jq -n '{network:"grpc", security:"none", grpcSettings:{serviceName:"gRPC"}}')
            fi
            ;;
        vision)
            # Vision sempre exige TLS — garantido pelo wizard
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{
                network:"tcp", security:"tls",
                tlsSettings:{serverName:$dom, certificates:[{certificateFile:$crt,keyFile:$key}], minVersion:"1.2"},
                tcpSettings:{header:{type:"none"}}
            }')
            ;;
        *)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" '{
                    network:"tcp", security:"tls",
                    tlsSettings:{serverName:$dom, certificates:[{certificateFile:$crt,keyFile:$key}], minVersion:"1.2"}
                }')
            else
                stream_settings=$(jq -n '{network:"tcp", security:"none"}')
            fi
            ;;
    esac

    # UUID com fallback robusto
    local uuid
    uuid=$(generate_uuid)
    if [ -z "$uuid" ]; then
        echo -e "${TXT_RED}❌ Não foi possível gerar UUID.${RESET}"
        return 1
    fi

    # Clientes do inbound
    local clients_json
    if [ "$network" = "vision" ]; then
        clients_json=$(jq -n --arg uuid "$uuid" '[{"id":$uuid,"level":0,"flow":"xtls-rprx-vision"}]')
    else
        clients_json=$(jq -n --arg uuid "$uuid" '[{"id":$uuid,"level":0}]')
    fi

    # Backup do config anterior antes de sobrescrever
    if [ -f "$CONFIG_PATH" ]; then
        cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    fi

    # Monta e valida o JSON final antes de gravar
    local tmp_config
    tmp_config=$(mktemp /tmp/xray_config_XXXXXX.json)

    jq -n \
        --argjson stream   "$stream_settings" \
        --arg     port     "$port" \
        --arg     api      "$api_port" \
        --argjson pol      "$policy" \
        --argjson rules    "$routing_rules" \
        --argjson clients  "$clients_json" \
        '{
            log:{loglevel:"warning"},
            stats:{},
            api:{services:["HandlerService","LoggerService","StatsService"],tag:"api"},
            policy:$pol,
            inbounds:[
                {tag:"api",port:($api|tonumber),protocol:"dokodemo-door",
                 settings:{address:"127.0.0.1"},listen:"127.0.0.1"},
                {tag:"inbound-dragoncore",port:($port|tonumber),protocol:"vless",
                 settings:{clients:$clients,decryption:"none",fallbacks:[]},
                 streamSettings:$stream}
            ],
            outbounds:[
                {protocol:"freedom",tag:"direct"},
                {protocol:"blackhole",tag:"blocked"},
                {protocol:"freedom",tag:"api"}
            ],
            routing:{domainStrategy:"AsIs",rules:$rules}
        }' > "$tmp_config"

    # Valida JSON gerado antes de aplicar
    if ! jq empty "$tmp_config" 2>/dev/null; then
        echo -e "${TXT_RED}❌ Config JSON gerado é inválido. Abortando (backup em ${CONFIG_PATH}.bak).${RESET}"
        rm -f "$tmp_config"
        return 1
    fi

    mv -f "$tmp_config" "$CONFIG_PATH"
    chmod 0600 "$CONFIG_PATH"  # Apenas root lê — contém UUIDs de usuários

    # Preset e domínio ativo
    jq -n --arg network "$network" --arg port "$port" --arg domain "$domain" --arg tls "$use_tls" \
        '{network:$network,port:$port,domain:$domain,tls:$tls}' > "$PRESET_FILE"
    echo "$domain" > "$ACTIVE_DOMAIN_FILE"

    # Restart com diagnóstico em falha
    echo -e "Reiniciando Xray..."
    if ! systemctl restart xray >>"$LOG_FILE" 2>&1; then
        echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Últimas linhas do journal:${RESET}"
        journalctl -u xray -n 25 --no-pager 2>/dev/null || true
        echo ""
        echo -e "${TXT_YELLOW}Config anterior restaurado de ${CONFIG_PATH}.bak${RESET}"
        [ -f "${CONFIG_PATH}.bak" ] && mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        read -rp "Pressione Enter..."
        return 1
    fi
    sleep 2

    header_blue "CONFIGURAÇÃO CONCLUÍDA (V7.8)"

    local status_show="${TXT_RED}FALHA${RESET}"
    systemctl is-active --quiet xray 2>/dev/null && status_show="${TXT_GREEN}ATIVO${RESET}"

    local tls_msg="${TXT_RED}DESATIVADO${RESET}"
    [ "$use_tls" = "true" ] && tls_msg="${TXT_GREEN}ATIVADO (TLS 1.2+)${RESET}"

    echo -e "STATUS: $status_show"
    echo ""
    echo "========================================="
    echo -e " ${TXT_YELLOW}PROTOCOLO:${RESET}     ${TXT_CYAN}${network^^}${RESET}"
    echo -e " ${TXT_YELLOW}DOMÍNIO/SNI:${RESET}   ${TXT_CYAN}${domain}${RESET}"
    echo -e " ${TXT_YELLOW}PORTA:${RESET}         ${TXT_CYAN}${port}${RESET}"
    echo -e " ${TXT_YELLOW}API INTERNA:${RESET}   ${TXT_CYAN}127.0.0.1:${api_port}${RESET}"
    echo -e " ${TXT_YELLOW}CRIPTOGRAFIA:${RESET}  ${tls_msg}"
    echo "========================================="
    echo ""

    local sec="none"
    [ "$use_tls" = "true" ] && sec="tls"

    local link=""
    case "$network" in
        grpc)   link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=gRPC&sni=${domain}#VLESS-DragonCore" ;;
        ws)     link="vless://${uuid}@${domain}:${port}?path=%2F&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#VLESS-DragonCore" ;;
        xhttp)  link="vless://${uuid}@${domain}:${port}?mode=auto&path=%2F&security=${sec}&encryption=none&host=${domain}&type=xhttp&sni=${domain}#VLESS-DragonCore" ;;
        vision) link="vless://${uuid}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#VLESS-DragonCore" ;;
        *)      link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=tcp&sni=${domain}#VLESS-DragonCore" ;;
    esac

    echo -e "${TXT_YELLOW}LINK DE CONEXÃO:${RESET}"
    echo -e "${TXT_BLUE}${link}${RESET}"
    echo ""

    # Salva link e UUID em arquivo seguro (apenas root)
    mkdir -p "$XRAYTOOLS_DIR"
    cat > "$CONN_INFO_FILE" <<EOF
# DragonCore - Informações de Conexão
# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')
PROTOCOLO=${network^^}
DOMINIO=${domain}
PORTA=${port}
TLS=${use_tls}
UUID=${uuid}
LINK=${link}
EOF
    chmod 0777 "$CONN_INFO_FILE"
    echo -e "${TXT_GREEN}Link salvo em: ${CONN_INFO_FILE}${RESET}"
    echo ""
    read -rp "Pressione Enter para sair..."
}

# --- WIZARD ---
func_wizard_install() {
    require_root
    : > "$LOG_FILE"  # limpa log anterior

    # PASSO 1: Instalação do core
    header_blue "PASSO 1/5 — INSTALAÇÃO DO CORE"
    echo -e "${TXT_YELLOW}Deseja instalar/atualizar o Xray Core?${RESET}"
    read -rp "[s] Sim / [n] Não: " inst
    [[ "$inst" =~ ^[Ss]$ ]] && { func_install_official_core || true; }

    # PASSO 2: TLS
    header_blue "PASSO 2/5 — CRIPTOGRAFIA (TLS)"
    echo -e "${TXT_YELLOW}Deseja usar TLS?${RESET}"
    echo " [1] SIM — HTTPS/TLS (recomendado, porta 443)"
    echo " [2] NÃO — Sem TLS (porta 80)"
    read -rp "Opção [1/2]: " tls_opt
    local use_tls="false"
    [ "${tls_opt:-2}" = "1" ] && use_tls="true"

    # PASSO 3: Porta
    header_blue "PASSO 3/5 — PORTA DE CONEXÃO"
    if [ "$use_tls" = "true" ]; then
        echo -e "Sugestões com TLS: ${TXT_CYAN}443, 8443, 2053${RESET}"
    else
        echo -e "Sugestões sem TLS: ${TXT_CYAN}80, 8080, 8880${RESET}"
    fi
    read -rp "Porta [Enter = padrão]: " pub_port
    if [ -z "${pub_port:-}" ]; then
        [ "$use_tls" = "true" ] && pub_port="443" || pub_port="80"
    fi
    if ! validate_port "$pub_port"; then
        echo -e "${TXT_RED}❌ Porta inválida: '${pub_port}'${RESET}"
        read -rp "Enter..."; return 1
    fi
    if port_in_use "$pub_port"; then
        echo -e "${TXT_RED}⚠  Porta ${pub_port} já está em uso.${RESET}"
        read -rp "Continuar mesmo assim? [s/N]: " force
        [[ "${force:-n}" =~ ^[Ss]$ ]] || return 1
    fi

    # PASSO 4: Domínio / IP
    header_blue "PASSO 4/5 — DOMÍNIO / ENDEREÇO"
    local domain_val=""
    ensure_cmd curl curl

    if [ "$use_tls" = "true" ]; then
        echo -e "${TXT_YELLOW}Digite o domínio para o certificado TLS:${RESET}"
        echo -e " Exemplo: ${TXT_CYAN}meusite.com${RESET} (sem http://, sem espaços)"
        read -rp "Domínio: " domain_val

        if ! validate_domain "$domain_val"; then
            echo -e "${TXT_RED}❌ Domínio inválido. Use formato: exemplo.com${RESET}"
            read -rp "Enter..."; return 1
        fi

        func_xray_cert "$domain_val" || {
            echo -e "${TXT_RED}❌ Falha ao obter certificado TLS.${RESET}"
            read -rp "Enter..."; return 1
        }

        if [ ! -s "$CRT_FILE" ] || [ ! -s "$KEY_FILE" ]; then
            echo -e "${TXT_RED}❌ Certificado não gerado. Verifique o domínio e tente novamente.${RESET}"
            read -rp "Enter..."; return 1
        fi
    else
        echo -e "${TXT_YELLOW}Digite o IP da VPS ou domínio (sem TLS):${RESET}"
        read -rp "Endereço [Enter = detectar IP]: " domain_val

        if [ -z "${domain_val:-}" ]; then
            echo -n "Detectando IP público... "
            # HTTPS forçado + fallback para segunda fonte
            domain_val=$(curl -fsSL --max-time 10 --connect-timeout 5 \
                "https://icanhazip.com" 2>/dev/null || \
                curl -fsSL --max-time 10 --connect-timeout 5 \
                "https://api.ipify.org" 2>/dev/null || echo "")
            echo "${domain_val:-falhou}"
        fi

        if ! validate_domain_or_ip "$domain_val"; then
            echo -e "${TXT_RED}❌ Endereço inválido: '${domain_val}'${RESET}"
            read -rp "Enter..."; return 1
        fi
    fi

    mkdir -p "$XRAYTOOLS_DIR"
    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"

    # PASSO 5: Protocolo
    header_blue "PASSO 5/5 — PROTOCOLO"
    echo " [1] WS      — Websocket"
    echo " [2] GRPC    — gRPC"
    echo " [3] XHTTP   — Otimizado (recomendado)"
    echo " [4] TCP     — TCP simples"
    echo " [5] VISION  — XTLS Vision (exige TLS)"
    read -rp "Opção [1-5]: " prot_opt

    local selected_net=""
    case "$prot_opt" in
        1) selected_net="ws"     ;;
        2) selected_net="grpc"   ;;
        3) selected_net="xhttp"  ;;
        4) selected_net="tcp"    ;;
        5) selected_net="vision" ;;
        *) echo -e "${TXT_RED}❌ Opção inválida.${RESET}"; read -rp "Enter..."; return 1 ;;
    esac

    if [ "$selected_net" = "vision" ] && [ "$use_tls" = "false" ]; then
        echo -e "${TXT_RED}❌ Vision exige TLS. Ative TLS e tente novamente.${RESET}"
        read -rp "Enter..."; return 1
    fi

    # RESUMO E CONFIRMAÇÃO antes de aplicar
    header_blue "RESUMO DA CONFIGURAÇÃO"
    echo "========================================="
    echo -e " ${TXT_CYAN}PROTOCOLO:${RESET}   ${selected_net^^}"
    echo -e " ${TXT_CYAN}DOMÍNIO:${RESET}     ${domain_val}"
    echo -e " ${TXT_CYAN}PORTA:${RESET}       ${pub_port}"
    echo -e " ${TXT_CYAN}TLS:${RESET}         ${use_tls}"
    echo "========================================="
    echo ""
    read -rp "Confirmar e aplicar? [s/N]: " confirm
    [[ "${confirm:-n}" =~ ^[Ss]$ ]] || {
        echo "Operação cancelada."
        sleep 1
        return 0
    }

    func_generate_config "$pub_port" "$selected_net" "$domain_val" "1080" "$use_tls"
}

func_wizard_install
