#!/bin/bash
# core_manager.sh - TURBONET XRAY V1.2.1 (Otimizado com Engenharia DragonCore)
# Correções aplicadas V1.2.1:
#   - Eliminado SIGPIPE (exit 141) sob pipefail na geração de senha/UUID/trojan (/dev/urandom com leitura limitada)
#   - Uso de `jq -c` em _build_initial_clients_and_sample para garantir JSON em linha única
#   - Removido mux inválido do outbound freedom e corrigido xhttpSettings ("headers" no plural)
#   - Preserva usuários ativos/bloqueados do users.db ao regenerar config.json (ou cria admin sincronizado)
#   - Detecção dinâmica do usuário/grupo do xray.service (_detect_xray_owner) e permissões 750/640

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; read -rp "Enter para continuar...";' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
XRAYTOOLS_DIR="/opt/XrayTools"
USER_DB="${XRAYTOOLS_DIR}/users.db"
ACTIVE_DOMAIN_FILE="${XRAYTOOLS_DIR}/active_domain"
CONN_INFO_FILE="${XRAYTOOLS_DIR}/connection_info.txt"
LOG_FILE="/tmp/core_manager.log"

SSL_DIR="/opt/TurbonetCoreSSL"
KEY_FILE="$SSL_DIR/privkey.pem"
CRT_FILE="$SSL_DIR/fullchain.pem"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

API_PORT="${XRAY_API_PORT:-1080}"

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

header_blue() { clear; echo -e "${TITLE_BAR}   $1   ${RESET}"; echo ""; }

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${TXT_RED}❌ Execute como root!${RESET}"
        exit 1
    fi
}

_detect_xray_owner() {
    local svc_user=""
    if command -v systemctl &>/dev/null; then
        svc_user=$(systemctl show -p User --value xray 2>/dev/null || true)
    fi
    svc_user="${svc_user:-nobody}"
    if ! id "$svc_user" &>/dev/null; then
        svc_user="root"
    fi
    XRAY_USER="$svc_user"
    XRAY_GROUP="$(id -gn "$XRAY_USER")"
}

_apply_config_perms() {
    _detect_xray_owner
    local cfg_dir
    cfg_dir="$(dirname "$CONFIG_PATH")"

    if [ -d "$cfg_dir" ]; then
        chown -R "root:${XRAY_GROUP}" "$cfg_dir"
        chmod 750 "$cfg_dir"
        find "$cfg_dir" -maxdepth 1 -type f -exec chmod 640 {} +
    fi

    if [ -f "$CONFIG_PATH" ]; then
        chown "root:${XRAY_GROUP}" "$CONFIG_PATH"
        chmod 640 "$CONFIG_PATH"
    fi

    if [ -f "$PRESET_FILE" ]; then
        chown "root:${XRAY_GROUP}" "$PRESET_FILE"
        chmod 640 "$PRESET_FILE"
    fi

    if [ -d "$SSL_DIR" ]; then
        chown -R "root:${XRAY_GROUP}" "$SSL_DIR"
        find "$SSL_DIR" -type d -exec chmod 750 {} +
        find "$SSL_DIR" -type f -exec chmod 640 {} +
    fi
}

_test_xray_config() {
    local cfg="$1"
    [ ! -x /usr/local/bin/xray ] && return 0
    _detect_xray_owner
    if command -v runuser &>/dev/null && [ "$XRAY_USER" != "root" ]; then
        runuser -u "$XRAY_USER" -- /usr/local/bin/xray run -test -config "$cfg"
    else
        /usr/local/bin/xray run -test -config "$cfg"
    fi
}

_check_shebang_bom_safe() {
    local file="$1"
    local first_line
    first_line=$(LC_ALL=C head -n 1 "$file" | sed 's/^\xEF\xBB\xBF//')
    [[ "$first_line" =~ ^#!.*(bash|sh|env[[:space:]]) ]]
}

validate_port() {
    local p="$1"
    if [[ "$p" =~ ^[0-9]{1,5}$ ]]; then
        if (( p >= 1 && p <= 65535 )); then return 0; fi
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

validate_domain_or_ip() {
    local d="${1:-}"
    d="$(echo "$d" | tr -d '[:space:][:cntrl:]')"
    if [ -z "$d" ]; then return 1; fi

    if [[ "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra parts <<< "$d"
        for p in "${parts[@]}"; do
            if ! (( p <= 255 )); then return 1; fi
        done

        local o1="${parts[0]}" o2="${parts[1]}"
        if [ "$o1" -eq 0 ] || [ "$o1" -eq 127 ]; then return 1; fi
        if [ "$o1" -eq 255 ]; then return 1; fi
        if [ "$o1" -eq 169 ] && [ "$o2" -eq 254 ]; then return 1; fi
        if (( o1 >= 224 && o1 <= 239 )); then return 1; fi
        if [ "$o1" -eq 10 ]; then return 1; fi
        if [ "$o1" -eq 172 ] && (( o2 >= 16 && o2 <= 31 )); then return 1; fi
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
        dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -x | head -1 | \
            awk '{print $2$3"-"$4"-4"substr($5,2)"-"substr($6,1,1)"8"substr($6,2)"-"$7$8}'
    fi
}

generate_trojan_password() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 16
    else
        dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
    fi
}

_generate_random_alnum() {
    local len="${1:-10}"
    head -c 128 /dev/urandom | tr -dc 'a-zA-Z0-9' | cut -c1-"$len"
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
        if ss -tlnp 2>/dev/null | grep -qE "(:|\])${port}\b"; then return 0; fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -qE ":${port}\b"; then return 0; fi
    elif command -v lsof &>/dev/null; then
        if lsof -Pi :"$port" -sTCP:LISTEN -t &>/dev/null; then return 0; fi
    fi
    return 1
}

_find_free_api_port() {
    local port="${1:-1080}"
    local max_port=1200
    while port_in_use "$port"; do
        port=$((port + 1))
        if [ "$port" -gt "$max_port" ]; then
            echo -e "${TXT_RED}❌ Nenhuma porta livre encontrada para a API (${1:-1080}-${max_port}).${RESET}" >&2
            return 1
        fi
    done
    echo "$port"
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

    if ! _check_shebang_bom_safe "$install_script"; then
        echo -e "${TXT_RED}❌ Script inválido.${RESET}"; rm -f "$install_script"; return 1
    fi

    chmod +x "$install_script"
    bash "$install_script" install
    rm -f "$install_script"

    # Injeção DragonCore: Blindagem de CPU e Limites de Arquivo
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 1)
    mkdir -p /etc/systemd/system/xray.service.d
    cat <<EOF > /etc/systemd/system/xray.service.d/override.conf
[Service]
LimitNOFILE=65536
LimitNPROC=65536
Restart=on-failure
RestartSec=3
Environment="GOMAXPROCS=${cpu_cores}"
EOF
    systemctl daemon-reload
    _apply_config_perms

    echo -e "${TXT_GREEN}Instalação e Tuning de CPU concluídos.${RESET}"
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

    if ! _check_shebang_bom_safe "$tmp"; then
        echo -e "${TXT_RED}❌ certxray.sh inválido.${RESET}"; rm -f "$tmp"; return 1
    fi

    mv -f "$tmp" "$cert_script"
    chmod 700 "$cert_script"
    chown root:root "$cert_script"
    bash "$cert_script" "$dom"
    _apply_config_perms
}

# Constrói lista de clientes preservando usuários existentes no users.db ou criando admin inicial
_build_initial_clients_and_sample() {
    local network="$1"
    local sample_cred=""
    local tmp_clients
    tmp_clients=$(mktemp /tmp/xray_clients_XXXXXX.json)
    echo "[]" > "$tmp_clients"

    declare -A old_locked
    if [ -s "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null; then
        while IFS= read -r lemail; do
            [ -n "$lemail" ] && old_locked["${lemail#LOCKED_}"]=1
        done < <(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") | .settings.clients[]? | select(.email? and (.email | startswith("LOCKED_"))) | .email' "$CONFIG_PATH" 2>/dev/null || true)
    fi

    local imported=0
    if [ -s "$USER_DB" ]; then
        while IFS='|' read -r nick cred expiry _rest; do
            nick="${nick//$'\r'/}"
            cred="${cred//$'\r'/}"
            [ -n "${nick:-}" ] && [ -n "${cred:-}" ] || continue

            if [ "$network" = "trojan" ]; then
                [[ "$cred" =~ ^[0-9a-fA-F]{32}$ ]] || continue
            else
                [[ "$cred" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || continue
            fi

            local email_out="$nick"
            local cred_out="$cred"
            if [ "${old_locked[$nick]:-0}" = "1" ]; then
                email_out="LOCKED_${nick}"
                if [ "$network" = "trojan" ]; then
                    cred_out=$(generate_trojan_password)
                else
                    cred_out=$(generate_uuid)
                fi
            else
                [ -z "$sample_cred" ] && sample_cred="$cred"
            fi

            if [ "$network" = "trojan" ]; then
                jq -c --arg pwd "$cred_out" --arg em "$email_out" \
                    '. + [{"password":$pwd,"email":$em,"level":0}]' "$tmp_clients" > "${tmp_clients}.new" && mv -f "${tmp_clients}.new" "$tmp_clients"
            elif [ "$network" = "vision" ]; then
                jq -c --arg id "$cred_out" --arg em "$email_out" \
                    '. + [{"id":$id,"email":$em,"level":0,"flow":"xtls-rprx-vision"}]' "$tmp_clients" > "${tmp_clients}.new" && mv -f "${tmp_clients}.new" "$tmp_clients"
            else
                jq -c --arg id "$cred_out" --arg em "$email_out" \
                    '. + [{"id":$id,"email":$em,"level":0}]' "$tmp_clients" > "${tmp_clients}.new" && mv -f "${tmp_clients}.new" "$tmp_clients"
            fi
            imported=$((imported + 1))
        done < "$USER_DB"
    fi

    if [ "$imported" -eq 0 ]; then
        local default_nick="admin"
        local default_exp
        default_exp=$(date -d "+30 days" +%F 2>/dev/null || date +%F)
        local default_pass
        default_pass=$(_generate_random_alnum 10)

        if [ "$network" = "trojan" ]; then
            sample_cred=$(generate_trojan_password)
            jq -n -c --arg pwd "$sample_cred" --arg em "$default_nick" \
                '[{"password":$pwd,"email":$em,"level":0}]' > "$tmp_clients"
        elif [ "$network" = "vision" ]; then
            sample_cred=$(generate_uuid)
            jq -n -c --arg id "$sample_cred" --arg em "$default_nick" \
                '[{"id":$id,"email":$em,"level":0,"flow":"xtls-rprx-vision"}]' > "$tmp_clients"
        else
            sample_cred=$(generate_uuid)
            jq -n -c --arg id "$sample_cred" --arg em "$default_nick" \
                '[{"id":$id,"email":$em,"level":0}]' > "$tmp_clients"
        fi

        mkdir -p "$XRAYTOOLS_DIR"
        echo "${default_nick}|${sample_cred}|${default_exp}|${default_pass}|0" >> "$USER_DB"
        chmod 600 "$USER_DB"
        chown root:root "$USER_DB"
    elif [ -z "$sample_cred" ]; then
        if [ "$network" = "trojan" ]; then
            sample_cred=$(generate_trojan_password)
        else
            sample_cred=$(generate_uuid)
        fi
    fi

    local clients_out
    clients_out=$(jq -c '.' "$tmp_clients")
    rm -f "$tmp_clients"
    printf '%s\n%s\n' "$sample_cred" "$clients_out"
}

_build_routing_rules() {
    local has_geosite=false has_geoip=false
    if [ -s "/usr/local/share/xray/geosite.dat" ] || [ -s "/usr/local/bin/geosite.dat" ]; then
        has_geosite=true
    fi
    if [ -s "/usr/local/share/xray/geoip.dat" ] || [ -s "/usr/local/bin/geoip.dat" ]; then
        has_geoip=true
    fi

    local rules='[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"}'

    if [ "$has_geosite" = true ]; then
        rules+=',{"type":"field","outboundTag":"blocked","domain":["geosite:category-ads-all"]}'
    fi

    if [ "$has_geoip" = true ]; then
        rules+=',{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}'
    else
        rules+=',{"type":"field","ip":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8"],"outboundTag":"blocked"}'
    fi

    rules+=']'
    echo "$rules"
}

func_generate_config() {
    local port="$1" network="$2" domain="$3" use_tls="$4"

    ensure_cmd jq jq
    mkdir -p "$(dirname "$CONFIG_PATH")" "$XRAYTOOLS_DIR" "$SSL_DIR"
    chmod 700 "$XRAYTOOLS_DIR"
    _apply_config_perms

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
    local routing_rules
    routing_rules=$(_build_routing_rules)

    local stream_settings=""

    case "$network" in
        xhttp)
            echo ""
            echo -e "${TXT_CYAN}Modo XHTTP:${RESET}"
            echo " [1] HTTP Injection / Operadora BR (chip sem dados)"
            echo " [2] Direto / CDN (conexão direta ou via Azion/Vercel)"
            echo " [3] SSHXHTTP (SSH via Proxy Porta 80 junto com XHTTP)"
            read -rp "Modo [1/2/3, Enter=1]: " xhttp_mode
            xhttp_mode="${xhttp_mode:-1}"

            local xhttp_host_field="$domain"
            echo ""
            read -rp "Host adicional CDN (Enter = usar só domínio): " extra_host
            extra_host=$(echo "${extra_host:-}" | tr -d '[:space:][:cntrl:]')
            [ -n "$extra_host" ] && xhttp_host_field="${domain},${extra_host}"

            if [ "$xhttp_mode" = "3" ]; then
                echo ""
                echo -e "${TXT_YELLOW}Nota: O transporte XHTTP não usa fallbacks na porta 443.${RESET}"
                echo -e " Para usar SSH junto, ative o ${TXT_CYAN}Proxy Unificado (Porta 80)${RESET} no módulo SSH Fallback."
            fi

            if [ "$xhttp_mode" = "1" ]; then
                if [ "$use_tls" = "true" ]; then
                    stream_settings=$(jq -n \
                        --arg dom  "$domain" \
                        --arg crt  "$CRT_FILE" \
                        --arg key  "$KEY_FILE" \
                        --arg host "$xhttp_host_field" \
                        '{network:"xhttp",security:"tls",
                        sockopt:{tcpNoDelay:true,tcpKeepAliveIdle:30,tcpKeepAliveInterval:10},
                        tlsSettings:{serverName:$dom,
                          certificates:[{certificateFile:$crt,keyFile:$key}],
                          alpn:["http/1.1"],minVersion:"1.2"},
                        xhttpSettings:{path:"/",host:$host,
                          scMaxBufferedPosts:3,
                          scMaxEachPostBytes:"131072",
                          scStreamUpServerSecs:"5-15",
                          xPaddingBytes:"0-0",
                          headers:{"X-Accel-Buffering":"no","Cache-Control":"no-store"}}}')
                else
                    stream_settings=$(jq -n \
                        --arg host "$xhttp_host_field" \
                        '{network:"xhttp",security:"none",
                        sockopt:{tcpNoDelay:true,tcpKeepAliveIdle:30,tcpKeepAliveInterval:10},
                        xhttpSettings:{path:"/",host:$host,
                          scMaxBufferedPosts:3,
                          scMaxEachPostBytes:"131072",
                          scStreamUpServerSecs:"5-15",
                          xPaddingBytes:"0-0",
                          headers:{"X-Accel-Buffering":"no","Cache-Control":"no-store"}}}')
                fi
            elif [ "$xhttp_mode" = "3" ]; then
                if [ "$use_tls" = "true" ]; then
                    stream_settings=$(jq -n \
                        --arg dom  "$domain" \
                        --arg crt  "$CRT_FILE" \
                        --arg key  "$KEY_FILE" \
                        --arg host "$xhttp_host_field" \
                        '{network:"xhttp",security:"tls",
                        sockopt:{tcpNoDelay:true,tcpKeepAliveIdle:30,tcpKeepAliveInterval:10},
                        tlsSettings:{serverName:$dom,
                          certificates:[{certificateFile:$crt,keyFile:$key}],
                          alpn:["h2","http/1.1"],minVersion:"1.2"},
                        xhttpSettings:{path:"/",host:$host,
                          scMaxBufferedPosts:10,
                          scMaxEachPostBytes:"262144",
                          scStreamUpServerSecs:"10-30",
                          xPaddingBytes:"0-0",
                          headers:{"X-Accel-Buffering":"no","Cache-Control":"no-store"}}}')
                else
                    stream_settings=$(jq -n \
                        --arg host "$xhttp_host_field" \
                        '{network:"xhttp",security:"none",
                        sockopt:{tcpNoDelay:true,tcpKeepAliveIdle:30,tcpKeepAliveInterval:10},
                        xhttpSettings:{path:"/",host:$host,
                          scMaxBufferedPosts:10,
                          scMaxEachPostBytes:"262144",
                          scStreamUpServerSecs:"10-30",
                          xPaddingBytes:"0-0",
                          headers:{"X-Accel-Buffering":"no","Cache-Control":"no-store"}}}')
                fi
            else
                if [ "$use_tls" = "true" ]; then
                    stream_settings=$(jq -n \
                        --arg dom  "$domain" \
                        --arg crt  "$CRT_FILE" \
                        --arg key  "$KEY_FILE" \
                        --arg host "$xhttp_host_field" \
                        '{network:"xhttp",security:"tls",
                        sockopt:{tcpNoDelay:true,tcpKeepAliveIdle:30,tcpKeepAliveInterval:10},
                        tlsSettings:{serverName:$dom,
                          certificates:[{certificateFile:$crt,keyFile:$key}],
                          alpn:["h2","http/1.1"],minVersion:"1.2"},
                        xhttpSettings:{path:"/",host:$host,
                          scMaxBufferedPosts:30,
                          scMaxEachPostBytes:"1000000",
                          scStreamUpServerSecs:"20-80",
                          xPaddingBytes:"100-1000",
                          headers:{"X-Accel-Buffering":"no","Cache-Control":"no-store"}}}')
                else
                    stream_settings=$(jq -n \
                        --arg host "$xhttp_host_field" \
                        '{network:"xhttp",security:"none",
                        sockopt:{tcpNoDelay:true,tcpKeepAliveIdle:30,tcpKeepAliveInterval:10},
                        xhttpSettings:{path:"/",host:$host,
                          scMaxBufferedPosts:30,
                          scMaxEachPostBytes:"1000000",
                          scStreamUpServerSecs:"20-80",
                          xPaddingBytes:"100-1000",
                          headers:{"X-Accel-Buffering":"no","Cache-Control":"no-store"}}}')
                fi
            fi ;;
        ws)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                    '{network:"ws",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.2"},wsSettings:{acceptProxyProtocol:false,path:"/"}}')
            else
                stream_settings=$(jq -n '{network:"ws",security:"none",wsSettings:{acceptProxyProtocol:false,path:"/"}}')
            fi ;;
        grpc)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                    '{network:"grpc",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.2"},grpcSettings:{serviceName:"gRPC"}}')
            else
                stream_settings=$(jq -n '{network:"grpc",security:"none",grpcSettings:{serviceName:"gRPC"}}')
            fi ;;
        vision)
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                '{network:"tcp",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.2"},tcpSettings:{header:{type:"none"}}}') ;;
        httpupgrade)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                    '{network:"httpupgrade",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.2"},httpupgradeSettings:{path:"/",host:$dom}}')
            else
                stream_settings=$(jq -n --arg dom "$domain" \
                    '{network:"httpupgrade",security:"none",httpupgradeSettings:{path:"/",host:$dom}}')
            fi ;;
        h2)
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                '{network:"h2",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],alpn:["h2"],minVersion:"1.2"},httpSettings:{path:"/",host:[$dom]}}') ;;
        trojan)
            stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                '{network:"tcp",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.2"},tcpSettings:{header:{type:"none"}}}') ;;
        *)
            if [ "$use_tls" = "true" ]; then
                stream_settings=$(jq -n --arg dom "$domain" --arg crt "$CRT_FILE" --arg key "$KEY_FILE" \
                    '{network:"tcp",security:"tls",tlsSettings:{serverName:$dom,certificates:[{certificateFile:$crt,keyFile:$key}],minVersion:"1.2"}}')
            else
                stream_settings=$(jq -n '{network:"tcp",security:"none"}')
            fi ;;
    esac

    local client_bundle credential clients_json
    client_bundle=$(_build_initial_clients_and_sample "$network")
    credential=$(echo "$client_bundle" | sed -n '1p')
    clients_json=$(echo "$client_bundle" | sed -n '2p')

    if [ -z "${credential:-}" ] || [ -z "${clients_json:-}" ]; then
        echo -e "${TXT_RED}❌ Falha ao gerar credenciais iniciais.${RESET}"; return 1
    fi

    if [ -f "$CONFIG_PATH" ]; then
        cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    fi

    local tmp_config; tmp_config=$(mktemp /tmp/xray_config_XXXXXX.json)

    local inbound_protocol="vless"
    if [ "$network" = "trojan" ]; then
        inbound_protocol="trojan"
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

    jq -n --arg network "$network" --arg proto "$inbound_protocol" --arg port "$port" --arg domain "$domain" --arg tls "$use_tls" \
        '{network:$network,protocol:$proto,port:$port,domain:$domain,tls:$tls}' > "$PRESET_FILE"
    _apply_config_perms

    echo "$domain" > "$ACTIVE_DOMAIN_FILE"
    chmod 600 "$ACTIVE_DOMAIN_FILE"
    chown root:root "$ACTIVE_DOMAIN_FILE"

    if ! _test_xray_config "$CONFIG_PATH" >>"$LOG_FILE" 2>&1; then
        echo -e "${TXT_RED}❌ Falha na validação do config.json pelo Xray:${RESET}"
        tail -n 15 "$LOG_FILE" 2>/dev/null || true
        if [ -f "${CONFIG_PATH}.bak" ]; then
            mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
            _apply_config_perms
        fi
        read -rp "Pressione Enter..."; return 1
    fi

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

    header_blue "CONFIGURAÇÃO CONCLUÍDA (V1.2.1)"

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
    echo -e " ${TXT_YELLOW}PROTOCOLO:${RESET}    ${TXT_CYAN}${network^^}${RESET}"
    echo -e " ${TXT_YELLOW}DOMÍNIO/SNI:${RESET}  ${TXT_CYAN}${domain}${RESET}"
    echo -e " ${TXT_YELLOW}PORTA:${RESET}        ${TXT_CYAN}${port}${RESET}"
    echo -e " ${TXT_YELLOW}API INTERNA:${RESET}  ${TXT_CYAN}127.0.0.1:${api_port}${RESET}"
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
            echo -e "${TXT_RED}❌ Endereço inválido ou não-roteável (IPs privados/loopback não são aceitos).${RESET}"
            read -rp "Enter..."; return 1
        fi
    fi

    mkdir -p "$XRAYTOOLS_DIR"
    chmod 700 "$XRAYTOOLS_DIR"
    echo "$domain_val" > "$ACTIVE_DOMAIN_FILE"
    chmod 600 "$ACTIVE_DOMAIN_FILE"

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
        echo -e "${TXT_RED}❌ Trojan exige TLS para funcionar corretamente.${RESET}"; read -rp "Enter..."; return 1
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

# --- MENU INTERATIVO ---
while true; do
    clear
    echo -e "${TITLE_BAR}   CORE MANAGER — TURBONET XRAY   ${RESET}"
    echo ""

    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e " STATUS DO SERVIÇO: ${TXT_GREEN}ATIVO E RODANDO${RESET}"
    else
        echo -e " STATUS DO SERVIÇO: ${TXT_RED}INATIVO${RESET}"
    fi
    echo ""
    echo -e "${TXT_CYAN}[1] Instalar/Configurar (Modo Assistente)${RESET}"
    echo -e "${TXT_CYAN}[2] Atualizar Binário Oficial do Xray${RESET}"
    echo -e "${TXT_RED}[3] Parar Xray Core${RESET}"
    echo -e "${TXT_GREEN}[4] Iniciar/Reiniciar Xray Core${RESET}"
    echo -e "${TXT_CYAN}[5] Ver Logs de Erro do Xray${RESET}"
    echo -e "${TXT_CYAN}[0] Voltar${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " opt

    case "${opt:-0}" in
        1)
            func_wizard_install
            ;;
        2)
            func_install_official_core
            _apply_config_perms
            systemctl restart xray >/dev/null 2>&1 || true
            read -rp "Enter..."
            ;;
        3)
            systemctl stop xray >/dev/null 2>&1
            echo -e "${TXT_RED}⛔ Xray Parado.${RESET}"
            read -rp "Enter..."
            ;;
        4)
            _apply_config_perms
            systemctl restart xray >/dev/null 2>&1 || true
            sleep 1
            if systemctl is-active --quiet xray; then
                echo -e "${TXT_GREEN}✅ Xray Rodando Perfeitamente!${RESET}"
            else
                echo -e "${TXT_RED}❌ Falha ao iniciar o Xray. Verifique os logs.${RESET}"
            fi
            read -rp "Enter..."
            ;;
        5)
            echo -e "${TXT_CYAN}=== Últimos 30 logs do Xray ===${RESET}"
            journalctl -u xray -n 30 --no-pager
            read -rp "Enter..."
            ;;
        0) exit 0 ;;
        *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
