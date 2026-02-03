#!/bin/bash
# core_manager.sh - DragonCore V7.6 (Lógica Solicitada)
# REGRA 1: TLS ATIVO -> Aceita qualquer domínio e CHAMA o certxray.sh (Tenta Let's Encrypt)
# REGRA 2: TLS OFF   -> Aceita qualquer domínio/IP e NÃO CHAMA certificado.

set -euo pipefail

# --- CONFIGURAÇÕES ---
CONFIG_PATH="/usr/local/etc/xray/config.json"
SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"
ACTIVE_DOMAIN_FILE="/opt/XrayTools/active_domain"

# URL de Dependências
REPO_BASE="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main"
CERT_SCRIPT_URL="$REPO_BASE/modulosxray/certxray.sh"

# CORES
TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
RESET='\033[0m'

# --- FUNÇÕES BÁSICAS ---
header_blue() {
    clear
    echo -e "${TITLE_BAR}   $1   ${RESET}"
    echo ""
}

ensure_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y "$2" >/dev/null 2>&1
    fi
}

validate_port() {
    if [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 )); then return 0; fi
    return 1
}

validate_domain_format() {
    local d="${1:-}"
    [ -n "$d" ] || return 1
    [[ "$d" =~ ^[^[:space:]]+$ ]] || return 1
    return 0
}

# --- INSTALADOR XRAY ---
func_install_official_core() {
    header_blue "INSTALANDO XRAY CORE"
    echo "Verificando dependências..."
    ensure_cmd unzip unzip
    ensure_cmd curl curl
    ensure_cmd socat socat

    echo "Baixando instalador..."
    rm -f /tmp/install_xray.sh
    curl -fsSL -o /tmp/install_xray.sh "https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    chmod +x /tmp/install_xray.sh
    bash /tmp/install_xray.sh install
    rm -f /tmp/install_xray.sh
    echo "Xray instalado."
    sleep 1
}

# --- CHAMADA DO CERTIFICADO (SÓ EXECUTA SE PEDIR) ---
func_xray_cert() {
    local dom="$1"
    local cert_script="/usr/local/bin/certxray.sh"
    
    # Baixa se não existir
    if [ ! -f "$cert_script" ]; then
        curl -fsSL -o "$cert_script" "$CERT_SCRIPT_URL"
        chmod +x "$cert_script"
    fi
    
    # Executa o script de certificado (Lá ele decide se é Let's Encrypt ou Auto)
    bash "$cert_script" "$dom"
}

# --- GERAÇÃO DO JSON ---
func_generate_config() {
    local port="$1"
    local network="$2"
    local domain="$3"
    local api_port="$4"
    local use_tls="$5"

    ensure_cmd jq jq
    mkdir -p "$(dirname "$CONFIG_PATH")"
    
    local stream_settings=""
    local policy='{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}},"system":{"statsInboundUplink":true,"statsInboundDownlink":true}}'
    local routing='[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}]'

    # --- MONTAGEM DO STREAM SETTINGS ---
    if [ "$network" == "xhttp" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg d "$domain" --arg c "$CRT_FILE" --arg k "$KEY_FILE" '{network:"xhttp",security:"tls",tlsSettings:{serverName:$d,certificates:[{certificateFile:$c,keyFile:$k}],alpn:["h2","http/1.1"],minVersion:"1.2"},xhttpSettings:{path:"/",scMaxBufferedPosts:30,scMaxEachPostBytes:"1000000",scStreamUpServerSecs:"20-80",xPaddingBytes:"100-1000"}}')
        else
            stream_settings=$(jq -n '{network:"xhttp",security:"none",xhttpSettings:{path:"/",scMaxBufferedPosts:30,scMaxEachPostBytes:"1000000",scStreamUpServerSecs:"20-80",xPaddingBytes:"100-1000"}}')
        fi
    elif [ "$network" == "ws" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg d "$domain" --arg c "$CRT_FILE" --arg k "$KEY_FILE" '{network:"ws",security:"tls",tlsSettings:{serverName:$d,certificates:[{certificateFile:$c,keyFile:$k}],minVersion:"1.2"},wsSettings:{acceptProxyProtocol:false,path:"/"}}')
        else
            stream_settings=$(jq -n '{network:"ws",security:"none",wsSettings:{acceptProxyProtocol:false,path:"/"}}')
        fi
    elif [ "$network" == "grpc" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg d "$domain" --arg c "$CRT_FILE" --arg k "$KEY_FILE" '{network:"grpc",security:"tls",tlsSettings:{serverName:$d,certificates:[{certificateFile:$c,keyFile:$k}],minVersion:"1.2"},grpcSettings:{serviceName:"gRPC"}}')
        else
            stream_settings=$(jq -n '{network:"grpc",security:"none",grpcSettings:{serviceName:"gRPC"}}')
        fi
    elif [ "$network" == "vision" ]; then
        # Vision sempre tem TLS
        stream_settings=$(jq -n --arg d "$domain" --arg c "$CRT_FILE" --arg k "$KEY_FILE" '{network:"tcp",security:"tls",tlsSettings:{serverName:$d,certificates:[{certificateFile:$c,keyFile:$k}],minVersion:"1.2"},tcpSettings:{header:{type:"none"}}}')
    else 
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg d "$domain" --arg c "$CRT_FILE" --arg k "$KEY_FILE" '{network:"tcp",security:"tls",tlsSettings:{serverName:$d,certificates:[{certificateFile:$c,keyFile:$k}],minVersion:"1.2"}}')
        else
            stream_settings=$(jq -n '{network:"tcp",security:"none"}')
        fi
    fi

    # JSON Final
    jq -n --argjson s "$stream_settings" --arg p "$port" --arg a "$api_port" --argjson pol "$policy" --argjson r "$routing" \
    '{log:{loglevel:"warning"}, stats:{}, api:{services:["HandlerService","LoggerService","StatsService"], tag:"api"}, policy:$pol, inbounds:[{tag:"api", port:($a|tonumber), protocol:"dokodemo-door", settings:{address:"127.0.0.1"}, listen:"127.0.0.1"},{tag:"inbound-dragoncore", port:($p|tonumber), protocol:"vless", settings:{clients:[], decryption:"none", fallbacks:[]}, streamSettings:$s}], outbounds:[{protocol:"freedom", tag:"direct"},{protocol:"blackhole", tag:"blocked"}], routing:{domainStrategy:"AsIs", rules:$r}}' > "$CONFIG_PATH"

    if [ "$network" == "vision" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow":"xtls-rprx-vision"}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    echo "{\"network\":\"$network\",\"port\":\"$port\",\"domain\":\"$domain\",\"tls\":\"$use_tls\"}" > "/usr/local/etc/xray/preset.json"

    systemctl restart xray >/dev/null 2>&1 || true
    sleep 2
    
    header_blue "INSTALAÇÃO CONCLUÍDA"
    local status_txt="${TXT_RED}FALHA${RESET}"
    if systemctl is-active --quiet xray; then status_txt="${TXT_GREEN}ATIVO${RESET}"; fi
    local tls_txt="${TXT_RED}DESATIVADO${RESET}"
    if [ "$use_tls" == "true" ]; then tls_txt="${TXT_GREEN}ATIVADO${RESET}"; fi

    echo -e " STATUS:       $status_txt"
    echo -e " PROTOCOLO:    ${TXT_CYAN}${network^^}${RESET}"
    echo -e " DOMÍNIO:      ${TXT_CYAN}${domain}${RESET}"
    echo -e " PORTA:        ${TXT_CYAN}${port}${RESET}"
    echo -e " TLS/SSL:      ${tls_txt}"
    echo ""

    ensure_cmd uuidgen uuid-runtime
    local uuid=$(uuidgen)
    local link=""
    local sec="none"; [ "$use_tls" == "true" ] && sec="tls"

    case "$network" in
        "grpc") link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=gRPC&sni=${domain}#VLESS";;
        "ws") link="vless://${uuid}@${domain}:${port}?path=%2F&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#VLESS";;
        "xhttp") link="vless://${uuid}@${domain}:${port}?mode=auto&path=%2F&security=${sec}&encryption=none&host=${domain}&type=xhttp&sni=${domain}#VLESS";;
        "vision") link="vless://${uuid}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#VLESS";;
        *) link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=tcp&sni=${domain}#VLESS";;
    esac
    
    echo -e "${TXT_YELLOW}LINK DE CONEXÃO:${RESET}"
    echo -e "${TXT_BLUE}${link}${RESET}"
    echo ""
    read -rp "Pressione Enter para sair..."
}

# --- WIZARD LÓGICO ---
func_wizard_install() {
    header_blue "PASSO 1: INSTALAÇÃO"
    echo -e "${TXT_YELLOW}Deseja instalar/atualizar o Xray Core?${RESET}"
    read -rp "[s] Sim / [n] Não: " inst
    if [[ "$inst" =~ ^[Ss]$ ]]; then func_install_official_core || true; fi

    header_blue "PASSO 2: CRIPTOGRAFIA (TLS)"
    echo -e "${TXT_YELLOW}Deseja usar TLS (Cadeado/HTTPS)?${RESET}"
    echo " [1] SIM (Recomendado: Porta 443)"
    echo " [2] NÃO (Recomendado: Porta 80)"
    read -rp "Opção: " tls_opt
    
    local use_tls="false"
    if [ "$tls_opt" == "1" ]; then use_tls="true"; fi

    header_blue "PASSO 3: PORTA DE CONEXÃO"
    if [ "$use_tls" == "true" ]; then
        echo -e "Sugestão TLS: 443, 8443, 2053"
    else
        echo -e "Sugestão SEM TLS: 80, 8080, 8880"
    fi
    read -rp "Digite a porta: " pub_port
    if ! validate_port "$pub_port"; then echo "Porta inválida."; read -rp "Enter..."; return 0; fi

    # Verificação de porta em uso (apenas aviso)
    ensure_cmd lsof lsof
    if lsof -Pi :"$pub_port" -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo -e "${TXT_RED}Aviso: Porta $pub_port em uso.${RESET}"
        read -rp "Continuar mesmo assim? (s/n): " force
        if [[ "$force" != "s" ]]; then return 0; fi
    fi

    header_blue "PASSO 4: DOMÍNIO / ENDEREÇO"
    
    local domain_val=""
    
    # --- AQUI ESTÁ A LÓGICA QUE VOCÊ PEDIU ---
    if [ "$use_tls" == "true" ]; then
        # MODO TLS ATIVO: 
        # Aceita qualquer domínio e CHAMA O GERADOR DE CERTIFICADO (Let's Encrypt)
        echo -e "${TXT_YELLOW}Digite o DOMÍNIO para o certificado:${RESET}"
        echo -e "(Ex: meudominio.com, site.fake.com - Qualquer um)"
        read -rp "Domínio: " domain_val
        
        if ! validate_domain_format "$domain_val"; then
            echo "Domínio inválido."; read -rp "Enter..."; return 0
        fi
        
        # Chama o script certxray.sh para tentar ativar o Let's Encrypt
        func_xray_cert "$domain_val" || true
        
    else
        # MODO TLS DESATIVADO:
        # Aceita qualquer coisa e NÃO GERA CERTIFICADO
        echo -e "${TXT_YELLOW}Digite o IP da VPS ou Domínio Cloudflare:${RESET}"
        read -rp "Endereço: " domain_val
        if [ -z "$domain_val" ]; then domain_val=$(curl -fsSL icanhazip.com 2>/dev/null); fi
        
        # NADA MAIS É FEITO AQUI. PULA GERAÇÃO DE CERTIFICADO.
    fi
    
    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"

    header_blue "PASSO 5: PROTOCOLO"
    echo " [1] WS (Websocket)"
    echo " [2] GRPC"
    echo " [3] XHTTP"
    echo " [4] TCP"
    echo " [5] VISION (Exige TLS)"
    read -rp "Opção: " prot_opt

    local selected_net=""
    case "$prot_opt" in
        1) selected_net="ws" ;;
        2) selected_net="grpc" ;;
        3) selected_net="xhttp" ;;
        4) selected_net="tcp" ;;
        5) selected_net="vision" ;;
        *) return 0 ;;
    esac

    # Segurança para Vision
    if [ "$selected_net" == "vision" ] && [ "$use_tls" == "false" ]; then
        echo "Erro: Vision exige TLS ativo."; read -rp "Enter..."; return 0
    fi

    # Gera configuração final
    func_generate_config "$pub_port" "$selected_net" "$domain_val" "1080" "$use_tls"
}

func_wizard_install
