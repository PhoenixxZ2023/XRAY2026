#!/bin/bash
# core_manager.sh - Módulo de Instalação e Configuração (DragonCore V7.4)
# Autor: PhoenixxZ2023
# Função: Instala Xray, Configura Protocolos (com fix TLS 1.0) e Gera VLESS.

set -euo pipefail

# --- CONFIGURAÇÕES ---
CONFIG_PATH="/usr/local/etc/xray/config.json"
SSL_DIR="/opt/DragonCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"
ACTIVE_DOMAIN_FILE="/opt/XrayTools/active_domain"

# URL para baixar dependências se faltarem (CertXray)
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

# --- FUNÇÕES AUXILIARES ---

header_blue() {
    clear
    echo -e "${TITLE_BAR}   $1   ${RESET}"
    echo ""
}

ensure_cmd() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y "$pkg" >/dev/null 2>&1
    fi
}

validate_port() {
    local p="$1"
    if [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( p >= 1 && p <= 65535 )); then
        return 0
    fi
    return 1
}

# --- INSTALAÇÃO DO CORE OFICIAL ---
func_install_core() {
    header_blue "INSTALANDO XRAY CORE"
    
    ensure_cmd unzip unzip
    ensure_cmd curl curl
    ensure_cmd socat socat

    echo "Baixando instalador oficial..."
    rm -f /tmp/install_xray.sh
    curl -fsSL -o /tmp/install_xray.sh "https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
    
    if [ ! -s "/tmp/install_xray.sh" ]; then
        echo -e "${TXT_RED}Erro no download do instalador.${RESET}"; sleep 2; return 1
    fi

    chmod +x /tmp/install_xray.sh
    bash /tmp/install_xray.sh install
    rm -f /tmp/install_xray.sh
    
    if [ -x "/usr/local/bin/xray" ]; then
        echo -e "${TXT_GREEN}Xray Core instalado com sucesso!${RESET}"
        sleep 2
    else
        echo -e "${TXT_RED}Falha na instalação.${RESET}"
        sleep 2
    fi
}

# --- CHAMADA DO CERTIFICADO ---
func_xray_cert() {
    local dom="$1"
    local cert_script="/usr/local/bin/certxray.sh"

    # Se o script de certificado não existir localmente, baixa da pasta de módulos
    if [ ! -f "$cert_script" ]; then
        echo "Baixando módulo de certificado..."
        curl -fsSL -o "$cert_script" "$CERT_SCRIPT_URL"
        chmod +x "$cert_script"
    fi
    
    bash "$cert_script" "$dom"
}

# --- GERAÇÃO DA CONFIGURAÇÃO (O CÉREBRO) ---
func_generate_config() {
    local port="$1"
    local network="$2"
    local domain="$3"
    local api_port="1080"
    local use_tls="$5"

    mkdir -p "$(dirname "$CONFIG_PATH")"
    ensure_cmd jq jq

    local stream_settings=""
    # Políticas de log e stats
    local policy='{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}},"system":{"statsInboundUplink":true,"statsInboundDownlink":true}}'
    # Regras de roteamento (Bloqueio Torrent/Private IP)
    local routing_rules='[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"},{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}]'

    # --- LÓGICA DE PROTOCOLOS (COM FIX TLS 1.0 PARA HTTP INJECTOR) ---
    
    if [ "$network" == "xhttp" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{
                network:"xhttp",
                security:"tls",
                tlsSettings:{
                    serverName:$dom,
                    certificates:[{certificateFile:$crt,keyFile:$key}],
                    alpn:["h2","http/1.1"],
                    minVersion:"1.0", 
                    allowInsecure:true
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
            stream_settings=$(jq -n '{network:"xhttp",security:"none",xhttpSettings:{path:"/",scMaxBufferedPosts:30,scMaxEachPostBytes:"1000000",scStreamUpServerSecs:"20-80",xPaddingBytes:"100-1000"}}')
        fi

    elif [ "$network" == "ws" ]; then
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{
                network:"ws",
                security:"tls",
                tlsSettings:{
                    serverName:$dom,
                    certificates:[{certificateFile:$crt,keyFile:$key}],
                    minVersion:"1.0",
                    allowInsecure:true
                },
                wsSettings:{acceptProxyProtocol:false,path:"/"}
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
                    certificates:[{certificateFile:$crt,keyFile:$key}],
                    minVersion:"1.0",
                    allowInsecure:true
                },
                grpcSettings:{serviceName:"gRPC"}
            }')
        else
            stream_settings=$(jq -n '{network:"grpc",security:"none",grpcSettings:{serviceName:"gRPC"}}')
        fi

    elif [ "$network" == "vision" ]; then
        # VISION: Exige TLS 1.2+ e Flow específico
        stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
        '{
            network:"tcp",
            security:"tls",
            tlsSettings:{
                serverName:$dom,
                certificates:[{certificateFile:$crt,keyFile:$key}],
                minVersion:"1.2"
            },
            tcpSettings:{header:{type:"none"}}
        }')

    else # TCP PADRÃO
        if [ "$use_tls" = "true" ]; then
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
            '{
                network:"tcp",
                security:"tls",
                tlsSettings:{
                    serverName:$dom,
                    certificates:[{certificateFile:$crt,keyFile:$key}],
                    minVersion:"1.0",
                    allowInsecure:true
                }
            }')
        else
            stream_settings=$(jq -n '{network:"tcp",security:"none"}')
        fi
    fi

    # Montagem final do JSON
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

    # Adiciona flow Vision se necessário (o jq anterior sobrescreveria se tentasse por direto)
    if [ "$network" == "vision" ]; then
        jq '(.inbounds[] | select(.tag == "inbound-dragoncore").settings) += {"flow":"xtls-rprx-vision"}' \
          "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    # Salva Preset para o menu ler depois
    echo "{\"network\":\"$network\",\"port\":\"$port\",\"domain\":\"$domain\",\"tls\":\"$use_tls\"}" > "/usr/local/etc/xray/preset.json"

    # Restart do Serviço
    systemctl restart xray >/dev/null 2>&1 || true
    sleep 2
    
    # --- EXIBIÇÃO FINAL ---
    header_blue "INSTALAÇÃO CONCLUÍDA"
    
    local status_show="${TXT_RED}ERRO${RESET}"
    if systemctl is-active --quiet xray; then status_show="${TXT_GREEN}ATIVO${RESET}"; fi
    
    local tls_msg="${TXT_RED}DESATIVADO${RESET}"
    if [ "$use_tls" == "true" ]; then tls_msg="${TXT_GREEN}ATIVADO (TLS 1.0+ Compatível)${RESET}"; fi
    if [ "$network" == "vision" ]; then tls_msg="${TXT_GREEN}ATIVADO (TLS 1.2+ Vision)${RESET}"; fi

    echo -e "STATUS DO SERVIÇO: $status_show"
    echo ""
    echo "========================================="
    echo -e " ${TXT_YELLOW}PROTOCOLO:${RESET}        ${TXT_CYAN}${network^^}${RESET}"
    echo -e " ${TXT_YELLOW}DOMÍNIO (SNI):${RESET}    ${TXT_CYAN}${domain}${RESET}"
    echo -e " ${TXT_YELLOW}PORTA:${RESET}            ${TXT_CYAN}${port}${RESET}"
    echo -e " ${TXT_YELLOW}CRIPTOGRAFIA:${RESET}     ${tls_msg}"
    echo -e " ${TXT_YELLOW}PROTEÇÃO:${RESET}         ${TXT_GREEN}TORRENT & LAN BLOQUEADOS${RESET}"
    echo "========================================="
    echo ""

    # Gera Link Template
    ensure_cmd uuidgen uuid-runtime
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
    
    echo -e "${TXT_YELLOW}UUID UNIVERSAL (Exemplo):${RESET}"
    echo -e "${TXT_CYAN}${uuid}${RESET}"
    echo ""
    echo -e "${TXT_YELLOW}LINK VLESS (TEMPLATE):${RESET}"
    echo -e "${TXT_BLUE}${link}${RESET}"
    echo ""
    echo "========================================="
    echo "NOTA: Crie um usuário real na Opção 1 do Menu."
    echo "========================================="
    read -rp "Enter para finalizar..."
}

# --- WIZARD INTERATIVO ---
func_wizard() {
    clear
    header_blue "CONFIGURAÇÃO XRAY"
    
    echo -e "${TXT_YELLOW}Deseja (re)instalar o Xray Core Oficial? [s/n]${RESET}"
    read -rp "Opção: " inst_opt
    if [[ "$inst_opt" =~ ^[Ss]$ ]]; then func_install_core; fi

    header_blue "SELEÇÃO DE PROTOCOLO"
    echo " [1] WS (Websocket) - Compatível"
    echo " [2] GRPC - Baixa Latência"
    echo " [3] XHTTP - Novo Padrão"
    echo " [4] TCP - Simples"
    echo " [5] VISION - Reality (Requer TLS)"
    echo " [0] Cancelar"
    echo ""
    read -rp "Escolha [1-5]: " prot_opt

    local net="ws"
    case "$prot_opt" in
        2) net="grpc";;
        3) net="xhttp";;
        4) net="tcp";;
        5) net="vision";;
        0) exit 0;;
        *) echo "Inválido"; sleep 1; exit 1;;
    esac

    echo ""; read -rp "Porta de Conexão (Ex: 80, 443): " port
    [ -z "$port" ] && port=80
    
    # Valida Porta em uso
    ensure_cmd lsof lsof
    if lsof -Pi :"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo -e "${TXT_RED}Erro: A porta $port já está em uso!${RESET}"
        read -rp "Enter para sair..."
        exit 1
    fi

    echo ""; echo -e "${TXT_YELLOW}Usar TLS/SSL? [s/n]${RESET}"
    read -rp "Opção: " tls_opt
    local use_tls="false"
    local domain=""

    if [[ "$tls_opt" =~ ^[Ss]$ ]]; then
        use_tls="true"
        echo ""; echo -e "${TXT_YELLOW}Digite seu Domínio (SNI):${RESET}"
        read -rp "Domínio: " domain
        
        if [ -z "$domain" ]; then
            echo "Erro: TLS exige domínio."; sleep 2; exit 1
        fi
        
        echo "$domain" > "$ACTIVE_DOMAIN_FILE"
        func_xray_cert "$domain"
    else
        read -rp "Domínio ou IP (Enter para automático): " domain
        [ -z "$domain" ] && domain=$(curl -fsSL icanhazip.com 2>/dev/null)
    fi

    # Trava de segurança Vision
    if [ "$net" == "vision" ] && [ "$use_tls" == "false" ]; then
        echo -e "${TXT_RED}Erro: Protocolo VISION exige TLS ativado.${RESET}"
        sleep 2; exit 1
    fi

    func_generate_config "$port" "$net" "$domain" "1080" "$use_tls"
}

# Executa o Wizard
func_wizard
