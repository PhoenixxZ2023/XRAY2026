#!/bin/bash
# vercel_relay.sh - TURBONET XRAY V1.1
# Configurador de CDN/Relay via Vercel para protocolo XHTTP.
# Correções aplicadas V1.1:
#   - Detecção automática de TLS/HTTP e path real do XHTTP no config.json
#   - api/index.js gerado com https.request (TLS) ou http.request (sem TLS) conforme inbound
#   - Link VLESS gerado com mode=packet-up (compatível com funções serverless da Vercel)
#   - Validação com `xray run -test`, permissões 750/640 root:$XRAY_GROUP e restart do Xray
#   - Filtro para ignorar clientes LOCKED_ ao gerar o link VLESS de exemplo

set -Eeuo pipefail

_TMP_FILES=()
_cleanup() {
    for f in "${_TMP_FILES[@]:-}"; do
        [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
    done
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
XRAY_BIN="/usr/local/bin/xray"
XRAYTOOLS_DIR="/opt/XrayTools"
CONN_INFO_FILE="${XRAYTOOLS_DIR}/connection_info.txt"
RELAY_INFO_FILE="${XRAYTOOLS_DIR}/vercel_relay.json"
LOG_FILE="/tmp/vercel_relay.log"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"; exit 1
fi

# --- DETECÇÃO DE DISTRO E DEPENDÊNCIAS ---
_PKG_MANAGER=""
_APT_UPDATED=0
_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else echo -e "${TXT_RED}❌ Gerenciador de pacotes não detectado.${RESET}"; exit 1; fi
}

ensure_cmd() {
    local cmd="$1" pkg="$2"
    command -v "$cmd" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >>"$LOG_FILE" 2>&1 || true; _APT_UPDATED=1; }
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
}

: > "$LOG_FILE"
ensure_cmd jq jq
ensure_cmd curl curl

# --- DETECÇÃO DINÂMICA DE DONO, PERMISSÕES E RESTART ---
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
        chown "root:${XRAY_GROUP}" "$cfg_dir"
        chmod 750 "$cfg_dir"
    fi

    if [ -f "$CONFIG_PATH" ]; then
        chown "root:${XRAY_GROUP}" "$CONFIG_PATH"
        chmod 0640 "$CONFIG_PATH"
    fi
}

_test_xray_config() {
    local cfg="$1"
    [ ! -x "$XRAY_BIN" ] && return 0
    _detect_xray_owner
    if command -v runuser &>/dev/null && [ "$XRAY_USER" != "root" ]; then
        runuser -u "$XRAY_USER" -- "$XRAY_BIN" run -test -config "$cfg"
    else
        "$XRAY_BIN" run -test -config "$cfg"
    fi
}

_wait_xray_active() {
    local tries=5
    while [ "$tries" -gt 0 ]; do
        systemctl is-active --quiet xray 2>/dev/null && return 0
        sleep 1
        tries=$((tries - 1))
    done
    return 1
}

_apply_and_restart_xray() {
    local tmp_file="$1"
    if ! jq empty "$tmp_file" 2>/dev/null; then
        echo -e "${TXT_RED}❌ JSON inválido gerado. Config não alterado.${RESET}"
        return 1
    fi

    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    mv -f "$tmp_file" "$CONFIG_PATH"
    _TMP_FILES=("${_TMP_FILES[@]/$tmp_file}")
    _apply_config_perms

    if ! _test_xray_config "$CONFIG_PATH" >>"$LOG_FILE" 2>&1; then
        echo -e "${TXT_RED}❌ Validação do config.json falhou. Revertendo...${RESET}"
        mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        _apply_config_perms
        return 1
    fi

    if ! systemctl restart xray >>"$LOG_FILE" 2>&1 || ! _wait_xray_active; then
        echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
        mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        _apply_config_perms
        systemctl restart xray >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

# --- HELPERS ---
_get_preset() {
    local key="$1"
    [ -f "$PRESET_FILE" ] || { echo ""; return; }
    jq -r ".${key} // empty" "$PRESET_FILE" 2>/dev/null || echo ""
}

_get_vps_ip() {
    curl -4fsSL --max-time 8 https://icanhazip.com 2>/dev/null || \
    curl -4fsSL --max-time 8 https://api.ipify.org 2>/dev/null || \
    echo ""
}

_check_xhttp() {
    [ -s "$CONFIG_PATH" ] || return 1
    jq -e '.inbounds[]? | select(.tag=="inbound-turbonet") |
           select(.streamSettings.network=="xhttp")' \
        "$CONFIG_PATH" >/dev/null 2>&1
}

_get_xhttp_port() {
    local p=""
    if [ -s "$CONFIG_PATH" ]; then
        p=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1)
    fi
    [ -n "${p:-}" ] || p=$(_get_preset "port")
    echo "${p:-443}"
}

_get_xhttp_security() {
    local sec=""
    if [ -s "$CONFIG_PATH" ]; then
        sec=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") | .streamSettings.security // "none"' "$CONFIG_PATH" 2>/dev/null | head -1)
    fi
    echo "${sec:-none}"
}

_get_xhttp_path() {
    local p=""
    if [ -s "$CONFIG_PATH" ]; then
        p=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") | .streamSettings.xhttpSettings.path // "/"' "$CONFIG_PATH" 2>/dev/null | head -1)
    fi
    [ -z "${p:-}" ] && p="/"
    [[ "$p" != /* ]] && p="/${p}"
    echo "$p"
}

_urlencode() {
    jq -rn --arg s "$1" '$s | @uri'
}

_sanitize_domain() {
    echo "${1:-}" | tr -d '[:space:][:cntrl:]' | sed -E 's|^https?://||; s|/.*$||'
}

# --- GERA OS ARQUIVOS DO RELAY PARA VERCEL ---
_generate_relay_files() {
    local vps_ip="$1"
    local vps_port="$2"
    local relay_path="$3"
    local use_tls="$4"
    local out_dir="$5"

    mkdir -p "${out_dir}/api"

    cat > "${out_dir}/vercel.json" << 'VEOF'
{
  "version": 2,
  "functions": {
    "api/index.js": {
      "memory": 128,
      "maxDuration": 30
    }
  },
  "rewrites": [
    { "source": "/(.*)", "destination": "/api/index" }
  ],
  "trailingSlash": false
}
VEOF

    cat > "${out_dir}/package.json" << 'PEOF'
{
  "name": "turbonet-xhttp-relay",
  "version": "1.1.0",
  "description": "TURBONET XRAY - XHTTP Relay for Vercel",
  "main": "api/index.js"
}
PEOF

    cat > "${out_dir}/api/index.js" << EOF
// TURBONET XRAY — XHTTP Relay V1.1
// Relay de baixo overhead para protocolo XHTTP via Vercel CDN
'use strict';

const http  = require('http');
const https = require('https');

const TARGET_HOST = '${vps_ip}';
const TARGET_PORT = ${vps_port};
const RELAY_PATH  = '${relay_path}';
const USE_TLS     = ${use_tls};

const clientMod = USE_TLS ? https : http;

module.exports = (req, res) => {
    if (RELAY_PATH !== '/' && !req.url.startsWith(RELAY_PATH)) {
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('Not Found');
        return;
    }

    const headers = {
        ...req.headers,
        host: TARGET_HOST + ':' + TARGET_PORT,
        'x-forwarded-for': req.headers['x-real-ip'] ||
                           req.headers['x-forwarded-for'] ||
                           req.socket?.remoteAddress || '',
    };

    delete headers['connection'];
    delete headers['keep-alive'];
    delete headers['proxy-connection'];
    delete headers['transfer-encoding'];

    const options = {
        hostname: TARGET_HOST,
        port:     TARGET_PORT,
        path:     req.url,
        method:   req.method,
        headers,
        ...(USE_TLS ? { rejectUnauthorized: false } : {}),
    };

    const proxy = clientMod.request(options, (proxyRes) => {
        res.writeHead(proxyRes.statusCode || 200, proxyRes.headers);
        proxyRes.pipe(res, { end: true });
    });

    proxy.on('error', (err) => {
        if (!res.headersSent) {
            res.writeHead(502, { 'Content-Type': 'text/plain' });
        }
        res.end('Bad Gateway: ' + err.message);
    });

    req.pipe(proxy, { end: true });
};
EOF

    chmod 644 "${out_dir}/vercel.json" \
               "${out_dir}/package.json" \
               "${out_dir}/api/index.js"
}

_build_cdn_link() {
    local uuid="$1" domain="$2" raw_path="$3"
    local enc_path
    enc_path=$(_urlencode "$raw_path")
    echo "vless://${uuid}@${domain}:443?mode=packet-up&security=tls&encryption=none&type=xhttp&host=${domain}&path=${enc_path}&sni=${domain}#XHTTP-CDN-TURBONET"
}

_get_active_sample_uuid() {
    [ -s "$CONFIG_PATH" ] || { echo ""; return; }
    jq -r '
        .inbounds[]? | select(.tag=="inbound-turbonet")
        | .settings.clients[]?
        | select(.email? and (.email | startswith("LOCKED_") | not))
        | .id // empty
    ' "$CONFIG_PATH" 2>/dev/null | head -1
}

# --- MENU ---
while true; do
    clear
    echo -e "${TITLE_BAR}   CDN / RELAY VERCEL — TURBONET XRAY   ${RESET}"
    echo ""

    local_network=$(_get_preset "network")
    local_domain=$(_get_preset "domain")
    local_port=$(_get_xhttp_port)

    echo -e " ${TXT_CYAN}Protocolo atual:${RESET} ${local_network:-não configurado}"
    echo -e " ${TXT_CYAN}Domínio/IP:${RESET}      ${local_domain:-não configurado}"
    echo -e " ${TXT_CYAN}Porta:${RESET}           ${local_port:-não configurado}"

    if [ -f "$RELAY_INFO_FILE" ]; then
        local_relay_domain=$(jq -r '.vercel_domain // ""' "$RELAY_INFO_FILE" 2>/dev/null || echo "")
        [ -n "$local_relay_domain" ] && \
            echo -e " ${TXT_GREEN}Relay ativo:${RESET}     ${local_relay_domain}"
    fi

    echo ""
    echo -e "${TXT_CYAN}[1] CONFIGURAR RELAY VERCEL (passo a passo)${RESET}"
    echo -e "${TXT_CYAN}[2] ATUALIZAR DOMÍNIO VERCEL (já fez deploy)${RESET}"
    echo -e "${TXT_CYAN}[3] GERAR ARQUIVOS DO RELAY (para fazer deploy)${RESET}"
    echo -e "${TXT_CYAN}[4] VER LINK COM CDN${RESET}"
    echo -e "${TXT_RED}[5] REMOVER RELAY (voltar para IP direto)${RESET}"
    echo -e "${TXT_CYAN}[0] VOLTAR${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " opt

    case "${opt:-0}" in

    # ============================================================
    1)  # CONFIGURAR RELAY — PASSO A PASSO
    # ============================================================
        clear
        echo -e "${TITLE_BAR}   CONFIGURAR RELAY VERCEL — PASSO A PASSO   ${RESET}"
        echo ""

        if ! _check_xhttp; then
            echo -e "${TXT_RED}❌ Xray não está configurado com XHTTP.${RESET}"
            echo ""
            echo -e " Antes de configurar o relay, acesse:"
            echo -e " ${TXT_CYAN}[04] INSTALAR/CONFIGURAR XRAY${RESET} → escolha ${TXT_YELLOW}[3] XHTTP${RESET}"
            echo ""
            read -rp "Enter para voltar..."; continue
        fi

        vps_ip=$(_get_vps_ip)
        vps_port=$(_get_xhttp_port)
        relay_path=$(_get_xhttp_path)
        sec_mode=$(_get_xhttp_security)
        use_tls="false"
        [ "$sec_mode" = "tls" ] && use_tls="true"

        echo -e "${TXT_YELLOW}📋 O QUE É O RELAY VERCEL${RESET}"
        echo ""
        echo " Em vez do cliente conectar diretamente ao IP da sua VPS,"
        echo " ele conecta ao domínio da Vercel (CDN gratuito) que"
        echo " repassa o tráfego para sua VPS de forma transparente."
        echo ""
        echo -e " ${TXT_GREEN}Benefício:${RESET} Oculta o IP da VPS em redes com bloqueio de data centers."
        echo -e " ${TXT_GREEN}Origem:${RESET}    ${vps_ip}:${vps_port} (TLS: ${use_tls} | Path: ${relay_path})"
        echo ""
        echo -e "${TXT_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${TXT_YELLOW}PASSO 1 — Criar conta na Vercel${RESET}"
        echo ""
        echo " 1. Acesse: https://vercel.com/signup"
        echo " 2. Crie uma conta gratuita (pode usar GitHub, GitLab ou email)"
        echo ""
        read -rp "Pressione Enter quando tiver a conta criada..."

        echo ""
        echo -e "${TXT_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${TXT_YELLOW}PASSO 2 — Gerar arquivos do relay${RESET}"
        echo ""

        out_dir="/tmp/turbonet_vercel_relay"
        rm -rf "$out_dir"
        _generate_relay_files "${vps_ip:-SEU_IP}" "$vps_port" "$relay_path" "$use_tls" "$out_dir"

        echo -e " Arquivos gerados em: ${TXT_CYAN}${out_dir}/${RESET}"
        echo ""
        ls -la "$out_dir/" "$out_dir/api/"
        echo ""
        read -rp "Pressione Enter para continuar..."

        echo ""
        echo -e "${TXT_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${TXT_YELLOW}PASSO 3 — Fazer deploy na Vercel${RESET}"
        echo ""
        echo " Opção A — Via GitHub (recomendado):"
        echo "  1. Crie um repositório PRIVADO no GitHub"
        echo "  2. Faça upload dos arquivos de ${out_dir}/"
        echo "  3. Na Vercel: New Project → Import Git Repository"
        echo "  4. Selecione o repositório → Deploy"
        echo ""
        echo " Opção B — Via Vercel CLI (avançado):"
        echo "  npm i -g vercel"
        echo "  cd ${out_dir}"
        echo "  vercel --prod"
        echo ""
        echo -e " ${TXT_RED}⚠  Use repositório PRIVADO — contém o IP da sua VPS!${RESET}"
        echo ""
        read -rp "Pressione Enter quando o deploy estiver concluído..."

        echo ""
        echo -e "${TXT_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${TXT_YELLOW}PASSO 4 — Inserir o domínio Vercel${RESET}"
        echo ""
        echo " Após o deploy, a Vercel gera um domínio como:"
        echo -e " ${TXT_GREEN}seu-projeto.vercel.app${RESET}"
        echo ""
        read -rp "Digite o domínio Vercel (ex: meu-relay.vercel.app): " vercel_domain
        vercel_domain=$(_sanitize_domain "${vercel_domain:-}")

        if [ -z "$vercel_domain" ]; then
            echo -e "${TXT_RED}❌ Domínio inválido.${RESET}"; sleep 2; continue
        fi

        echo ""
        echo -e "${TXT_YELLOW}Testando conectividade com o relay...${RESET}"
        if curl -fsSL --max-time 10 "https://${vercel_domain}${relay_path}" >/dev/null 2>&1; then
            echo -e "${TXT_GREEN}✅ Relay acessível!${RESET}"
        else
            echo -e "${TXT_YELLOW}⚠  Não foi possível verificar o relay (normal se o Xray responder apenas a POST XHTTP).${RESET}"
        fi

        echo ""
        echo -e "${TXT_YELLOW}PASSO 5 — Atualizando config do Xray para aceitar CDN...${RESET}"

        tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
        _TMP_FILES+=("$tmp_cfg")
        if jq --arg cdnhost "$vercel_domain" \
            '(.inbounds[] | select(.tag=="inbound-turbonet") |
             .streamSettings.xhttpSettings) = ((.inbounds[] | select(.tag=="inbound-turbonet") | .streamSettings.xhttpSettings // {}) + {"host": $cdnhost})' \
            "$CONFIG_PATH" > "$tmp_cfg" 2>>"$LOG_FILE" && \
            _apply_and_restart_xray "$tmp_cfg"; then
            echo -e "${TXT_GREEN}✅ Config atualizado e Xray reiniciado.${RESET}"
        else
            echo -e "${TXT_YELLOW}⚠  Não foi possível atualizar o config automaticamente.${RESET}"
        fi

        mkdir -p "$XRAYTOOLS_DIR"
        chmod 700 "$XRAYTOOLS_DIR"
        jq -n \
            --arg vps_ip    "$vps_ip" \
            --arg vps_port  "$vps_port" \
            --arg domain    "$vercel_domain" \
            --arg path      "$relay_path" \
            --arg use_tls   "$use_tls" \
            --arg created   "$(date '+%Y-%m-%d %H:%M:%S')" \
            '{vps_ip:$vps_ip,vps_port:$vps_port,vercel_domain:$domain,path:$path,use_tls:$use_tls,created:$created}' \
            > "$RELAY_INFO_FILE"
        chmod 600 "$RELAY_INFO_FILE"

        local_uuid=$(_get_active_sample_uuid)

        echo ""
        echo -e "${TXT_GREEN}=================================================${RESET}"
        echo -e "${TXT_GREEN}✅ RELAY VERCEL CONFIGURADO COM SUCESSO!${RESET}"
        echo -e "${TXT_GREEN}=================================================${RESET}"
        echo -e " Relay:  ${TXT_CYAN}https://${vercel_domain}${RESET}"
        echo -e " VPS:    ${TXT_CYAN}${vps_ip}:${vps_port}${RESET} (oculto)"
        if [ -n "$local_uuid" ]; then
            local_link=$(_build_cdn_link "$local_uuid" "$vercel_domain" "$relay_path")
            echo ""
            echo -e " ${TXT_YELLOW}Link VLESS com CDN:${RESET}"
            echo -e " ${TXT_BLUE}${local_link}${RESET}"
            if [ -f "$CONN_INFO_FILE" ]; then
                sed -i '/^LINK_CDN=/d' "$CONN_INFO_FILE" 2>/dev/null || true
                echo "LINK_CDN=${local_link}" >> "$CONN_INFO_FILE"
            fi
        fi
        echo -e "${TXT_GREEN}=================================================${RESET}"
        echo ""
        read -rp "Enter para voltar..."
        ;;

    # ============================================================
    2)  # ATUALIZAR DOMÍNIO VERCEL
    # ============================================================
        echo ""
        read -rp "Novo domínio Vercel (ex: meu-relay.vercel.app): " new_domain
        new_domain=$(_sanitize_domain "${new_domain:-}")

        if [ -z "$new_domain" ]; then
            echo -e "${TXT_RED}❌ Domínio inválido.${RESET}"; sleep 2; continue
        fi

        if [ -f "$RELAY_INFO_FILE" ]; then
            tmp_rel=$(mktemp "${RELAY_INFO_FILE}.tmp.XXXXXX")
            _TMP_FILES+=("$tmp_rel")
            jq --arg d "$new_domain" '.vercel_domain = $d' "$RELAY_INFO_FILE" > "$tmp_rel" && \
                mv -f "$tmp_rel" "$RELAY_INFO_FILE"
            _TMP_FILES=("${_TMP_FILES[@]/$tmp_rel}")
            chmod 600 "$RELAY_INFO_FILE"
        fi

        tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
        _TMP_FILES+=("$tmp_cfg")
        if jq --arg cdnhost "$new_domain" \
            '(.inbounds[] | select(.tag=="inbound-turbonet") |
             .streamSettings.xhttpSettings.host) = $cdnhost' \
            "$CONFIG_PATH" > "$tmp_cfg" 2>>"$LOG_FILE" && \
            _apply_and_restart_xray "$tmp_cfg"; then
            echo -e "${TXT_GREEN}✅ Domínio atualizado para: ${new_domain}${RESET}"
        else
            echo -e "${TXT_RED}❌ Falha ao atualizar config.${RESET}"
        fi
        sleep 2
        ;;

    # ============================================================
    3)  # GERAR ARQUIVOS (sem configurar)
    # ============================================================
        vps_ip=$(_get_vps_ip)
        vps_port=$(_get_xhttp_port)
        relay_path=$(_get_xhttp_path)
        sec_mode=$(_get_xhttp_security)
        use_tls="false"
        [ "$sec_mode" = "tls" ] && use_tls="true"

        out_dir="/tmp/turbonet_vercel_relay"
        rm -rf "$out_dir"
        _generate_relay_files "${vps_ip:-SEU_IP}" "${vps_port:-443}" "$relay_path" "$use_tls" "$out_dir"

        echo ""
        echo -e "${TXT_GREEN}✅ Arquivos gerados em: ${out_dir}/${RESET}"
        echo -e " Origem: ${TXT_CYAN}${vps_ip:-SEU_IP}:${vps_port}${RESET} (TLS: ${use_tls} | Path: ${relay_path})"
        echo ""
        echo " Estrutura:"
        find "$out_dir" -type f | sort | while read -r f; do
            echo "  ${f#$out_dir/}"
        done
        echo ""
        echo -e " ${TXT_YELLOW}Faça upload desses arquivos para um repositório PRIVADO${RESET}"
        echo -e " no GitHub e importe na Vercel para fazer o deploy."
        echo ""
        read -rp "Enter para voltar..."
        ;;

    # ============================================================
    4)  # VER LINK COM CDN
    # ============================================================
        if [ ! -f "$RELAY_INFO_FILE" ]; then
            echo -e "${TXT_RED}❌ Relay não configurado. Use a opção [1].${RESET}"
            sleep 2; continue
        fi

        vercel_domain=$(jq -r '.vercel_domain // ""' "$RELAY_INFO_FILE" 2>/dev/null || echo "")
        relay_path=$(_get_xhttp_path)
        local_uuid=$(_get_active_sample_uuid)

        echo ""
        if [ -n "$local_uuid" ] && [ -n "$vercel_domain" ]; then
            local_link=$(_build_cdn_link "$local_uuid" "$vercel_domain" "$relay_path")
            echo -e "${TXT_YELLOW}Link VLESS com CDN Vercel:${RESET}"
            echo -e "${TXT_BLUE}${local_link}${RESET}"
        else
            echo -e "${TXT_RED}❌ Usuário ativo ou domínio não encontrado.${RESET}"
        fi
        echo ""
        read -rp "Enter para voltar..."
        ;;

    # ============================================================
    5)  # REMOVER RELAY
    # ============================================================
        echo ""
        read -rp "Confirmar remoção do relay? [s/N]: " conf
        [[ "${conf:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; continue; }

        if [ -s "$CONFIG_PATH" ]; then
            tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
            _TMP_FILES+=("$tmp_cfg")
            jq 'del(.inbounds[] | select(.tag=="inbound-turbonet") |
                   .streamSettings.xhttpSettings.host)' \
                "$CONFIG_PATH" > "$tmp_cfg" 2>>"$LOG_FILE" && \
                _apply_and_restart_xray "$tmp_cfg" || true
        fi

        rm -f "$RELAY_INFO_FILE"
        if [ -f "$CONN_INFO_FILE" ]; then
            sed -i '/^LINK_CDN=/d' "$CONN_INFO_FILE" 2>/dev/null || true
        fi
        echo -e "${TXT_GREEN}✅ Relay removido. Conexão voltou ao IP direto.${RESET}"
        sleep 2
        ;;

    0) exit 0 ;;
    *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
