#!/bin/bash
# core_manager.sh - Instalação e Configuração do Xray
# Contém as validações de porta, TLS e geração de JSON.

CONFIG_PATH="/usr/local/etc/xray/config.json"
SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"
ACTIVE_DOMAIN_FILE="/opt/XrayTools/active_domain"

# URL para baixar o certxray se necessário (ajuste o REPO se precisar)
REPO_BASE="https://raw.githubusercontent.com/PhoenixxZ2023/XrayX-TLS/main"
CERT_URL="$REPO_BASE/modulosxray/certxray.sh"

# Cores
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

header_blue() { clear; echo -e "${TITLE_BAR}   $1   ${RESET}"; echo ""; }

validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( p >= 1 && p <= 65535 ))
}

func_install_core() {
    header_blue "INSTALANDO XRAY CORE"
    apt-get update -y >/dev/null 2>&1
    apt-get install unzip curl socat -y >/dev/null 2>&1
    
    rm -f /tmp/install_xray.sh
    curl -fsSL -o /tmp/install_xray.sh "https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    chmod +x /tmp/install_xray.sh
    bash /tmp/install_xray.sh install
    rm -f /tmp/install_xray.sh
    
    if [ -x "/usr/local/bin/xray" ]; then
        echo -e "${TXT_GREEN}Xray Instalado!${RESET}"; sleep 2
    else
        echo -e "${TXT_RED}Falha na instalação.${RESET}"; sleep 2
    fi
}

func_xray_cert() {
    local dom="$1"
    # Baixa o certxray temporariamente se não existir
    if [ ! -f "/usr/local/bin/certxray.sh" ]; then
        curl -fsSL -o /usr/local/bin/certxray.sh "$CERT_URL"
        chmod +x /usr/local/bin/certxray.sh
    fi
    bash /usr/local/bin/certxray.sh "$dom"
}

func_generate_config() {
    local port="$1"
    local network="$2"
    local domain="$3"
    local api_port="1080"
    local use_tls="$5"

    mkdir -p "$(dirname "$CONFIG_PATH")"
    local stream_settings=""
    local policy='{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}},"system":{"statsInboundUplink":true,"statsInboundDownlink":true}}'
    local routing_rules='[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}]'

    # Lógica JSON (Exatamente como no seu menu original)
    if [ "$network" == "xhttp" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{network:"xhttp",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],alpn:["h2","http/1.1"],minVersion:"1.2"},xhttpSettings:{path:"/",scMaxBufferedPosts:30,scMaxEachPostBytes:"1000000",scStreamUpServerSecs:"20-80",xPaddingBytes:"100-1000"}}')
        else
            stream_settings=$(jq -n '{network:"xhttp",security:"none",xhttpSettings:{path:"/",scMaxBufferedPosts:30,scMaxEachPostBytes:"1000000",scStreamUpServerSecs:"20-80",xPaddingBytes:"100-1000"}}')
        fi
    elif [ "$network" == "ws" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{network:"ws",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.2"},wsSettings:{acceptProxyProtocol:false,path:"/"}}')
        else
            stream_settings=$(jq -n '{network:"ws",security:"none",wsSettings:{acceptProxyProtocol:false,path:"/"}}')
        fi
    elif [ "$network" == "grpc" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{network:"grpc",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.2"},grpcSettings:{serviceName:"gRPC"}}')
        else
            stream_settings=$(jq -n '{network:"grpc",security:"none",grpcSettings:{serviceName:"gRPC"}}')
        fi
    elif [ "$network" == "vision" ]; then
        stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
        '{network:"tcp",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.2"},tcpSettings:{header:{type:"none"}}}')
    else # tcp
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{network:"tcp",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.2"}}')
        else
            stream_settings=$(jq -n '{network:"tcp",security:"none"}')
        fi
    fi

    jq -n --argjson stream "$stream_settings" --arg port "$port" --arg api "$api_port" --argjson pol "$policy" --argjson rules "$routing_rules" \
      '{log:{loglevel:"warning"},stats:{},api:{services:["HandlerService","LoggerService","StatsService"],tag:"api"},policy:$pol,inbounds:[{tag:"api",port:($api|tonumber),protocol:"dokodemo-door",settings:{address:"127.0.0.1"},listen:"127.0.0.1"},{tag:"inbound-dragoncore",port:($port|tonumber),protocol:"vless",settings:{clients:[],decryption:"none",fallbacks:[]},streamSettings:$stream}],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"blocked"}],routing:{domainStrategy:"AsIs",rules:$rules}}' > "$CONFIG_PATH"

    if [ "$network" == "vision" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow":"xtls-rprx-vision"}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    # Preset
    echo "{\"network\":\"$network\",\"port\":\"$port\",\"domain\":\"$domain\",\"tls\":\"$use_tls\"}" > "/usr/local/etc/xray/preset.json"

    systemctl restart xray >/dev/null 2>&1 || true
    sleep 2
    
    header_blue "INSTALAÇÃO CONCLUÍDA"
    echo -e "Protocolo: ${TXT_CYAN}${network^^}${RESET} | Porta: ${TXT_CYAN}${port}${RESET}"
    [ "$use_tls" == "true" ] && echo -e "TLS: ${TXT_GREEN}ATIVO${RESET} | Domínio: ${TXT_CYAN}$domain${RESET}"
    
    # Exibe Link Template
    local uuid=$(uuidgen)
    local link=""
    local sec="none"; [ "$use_tls" == "true" ] && sec="tls"
    
    case "$network" in
        "grpc") link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=gRPC&sni=${domain}#VLESS_BASE";;
        "ws") link="vless://${uuid}@${domain}:${port}?path=%2F&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#VLESS_BASE";;
        "xhttp") link="vless://${uuid}@${domain}:${port}?mode=auto&path=%2F&security=${sec}&encryption=none&host=${domain}&type=xhttp&sni=${domain}#VLESS_BASE";;
        "vision") link="vless://${uuid}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#VLESS_BASE";;
        *) link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=tcp&sni=${domain}#VLESS_BASE";;
    esac
    
    echo ""; echo -e "${TXT_YELLOW}Link Template:${RESET}"; echo -e "${TXT_BLUE}$link${RESET}"
    echo ""; read -rp "Enter para finalizar..."
}

# WIZARD PRINCIPAL
func_wizard() {
    clear
    header_blue "CONFIGURAÇÃO XRAY"
    echo -e "${TXT_YELLOW}Instalar Xray Core? [s/n]${RESET}"
    read -rp "Opção: " inst_opt
    if [[ "$inst_opt" =~ ^[Ss]$ ]]; then func_install_core; fi

    header_blue "CONFIGURAÇÃO DE REDE"
    echo " [1] WS (Websocket)"
    echo " [2] GRPC"
    echo " [3] XHTTP"
    echo " [4] TCP"
    echo " [5] VISION"
    read -rp "Protocolo: " prot_opt
    local net="ws"
    case "$prot_opt" in 2) net="grpc";; 3) net="xhttp";; 4) net="tcp";; 5) net="vision";; esac

    echo ""; read -rp "Porta (Ex: 80, 443): " port
    [ -z "$port" ] && port=80
    if ! validate_port "$port"; then echo "Porta inválida"; sleep 2; exit 1; fi

    echo ""; read -rp "Usar TLS? [s/n]: " tls_opt
    local use_tls="false"
    local domain=""

    if [[ "$tls_opt" =~ ^[Ss]$ ]]; then
        use_tls="true"
        echo ""; read -rp "Domínio (SNI): " domain
        [ -z "$domain" ] && { echo "Domínio obrigatório para TLS"; sleep 2; exit 1; }
        echo "$domain" > "$ACTIVE_DOMAIN_FILE"
        func_xray_cert "$domain"
    else
        read -rp "Domínio/IP (Enter p/ auto): " domain
        [ -z "$domain" ] && domain=$(curl -fsSL icanhazip.com 2>/dev/null)
    fi

    if [ "$net" == "vision" ] && [ "$use_tls" == "false" ]; then
        echo "Erro: Vision exige TLS."; sleep 2; exit 1
    fi

    func_generate_config "$port" "$net" "$domain" "1080" "$use_tls"
}

func_wizard
