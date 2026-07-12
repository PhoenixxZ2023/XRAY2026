#!/bin/bash
# vercel_relay.sh - TURBONET XRAY V1.0
# Configurador de CDN/Relay via Vercel para protocolo XHTTP.
# Permite ocultar o IP da VPS usando a infraestrutura da Vercel como intermediário.
#
# Fluxo: Cliente VPN → Vercel CDN → Seu servidor Xray
#
# Pré-requisito: Xray configurado com XHTTP (opção 3 do core_manager.sh)

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
XRAYTOOLS_DIR="/opt/XrayTools"
CONN_INFO_FILE="${XRAYTOOLS_DIR}/connection_info.txt"
RELAY_INFO_FILE="${XRAYTOOLS_DIR}/vercel_relay.json"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"; exit 1
fi

# --- HELPERS ---
_apply_config_perms() {
    chmod 0640 "$CONFIG_PATH"
    chown root:nogroup "$CONFIG_PATH"
}

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

# Verifica se o Xray está configurado com XHTTP
_check_xhttp() {
    [ -s "$CONFIG_PATH" ] || return 1
    jq -e '.inbounds[]? | select(.tag=="inbound-turbonet") |
           select(.streamSettings.network=="xhttp")' \
        "$CONFIG_PATH" >/dev/null 2>&1
}

# --- GERA OS ARQUIVOS DO RELAY PARA VERCEL ---
_generate_relay_files() {
    local vps_ip="$1"
    local vps_port="$2"
    local relay_path="$3"
    local out_dir="$4"

    mkdir -p "${out_dir}/api"

    # vercel.json
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

    # package.json
    cat > "${out_dir}/package.json" << 'PEOF'
{
  "name": "turbonet-xhttp-relay",
  "version": "1.0.0",
  "description": "TURBONET XRAY - XHTTP Relay for Vercel",
  "main": "api/index.js"
}
PEOF

    # api/index.js — relay Node.js
    cat > "${out_dir}/api/index.js" << EOF
// TURBONET XRAY — XHTTP Relay V1.0
// Relay de baixo overhead para protocolo XHTTP via Vercel CDN
'use strict';

const http  = require('http');
const https = require('https');

const TARGET_HOST = '${vps_ip}';
const TARGET_PORT = ${vps_port};
const RELAY_PATH  = '${relay_path}';

module.exports = (req, res) => {
    // Verifica path
    if (!req.url.startsWith(RELAY_PATH)) {
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('Not Found');
        return;
    }

    const options = {
        hostname: TARGET_HOST,
        port:     TARGET_PORT,
        path:     req.url,
        method:   req.method,
        headers:  {
            ...req.headers,
            host: TARGET_HOST + ':' + TARGET_PORT,
            'x-forwarded-for': req.headers['x-real-ip'] ||
                               req.headers['x-forwarded-for'] ||
                               req.socket?.remoteAddress || '',
        },
    };

    // Remove headers que podem causar problema no relay
    delete options.headers['connection'];
    delete options.headers['keep-alive'];

    const proxy = http.request(options, (proxyRes) => {
        res.writeHead(proxyRes.statusCode, proxyRes.headers);
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

# --- MENU ---
while true; do
    clear
    echo -e "${TITLE_BAR}   CDN / RELAY VERCEL — TURBONET XRAY   ${RESET}"
    echo ""

    # Status atual
    local_network=$(_get_preset "network")
    local_domain=$(_get_preset "domain")
    local_port=$(_get_preset "port")

    echo -e " ${TXT_CYAN}Protocolo atual:${RESET} ${local_network:-não configurado}"
    echo -e " ${TXT_CYAN}Domínio/IP:${RESET}      ${local_domain:-não configurado}"
    echo -e " ${TXT_CYAN}Porta:${RESET}           ${local_port:-não configurado}"

    # Verifica se relay já está configurado
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

        # Verifica pré-requisito: XHTTP configurado
        if ! _check_xhttp; then
            echo -e "${TXT_RED}❌ Xray não está configurado com XHTTP.${RESET}"
            echo ""
            echo -e " Antes de configurar o relay, acesse:"
            echo -e " ${TXT_CYAN}[04] INSTALAR/CONFIGURAR XRAY${RESET} → escolha ${TXT_YELLOW}[3] XHTTP${RESET}"
            echo ""
            read -rp "Enter para voltar..."; continue
        fi

        vps_ip=$(_get_vps_ip)
        vps_port=$(_get_preset "port")
        relay_path="/"

        echo -e "${TXT_YELLOW}📋 O QUE É O RELAY VERCEL${RESET}"
        echo ""
        echo " Em vez do cliente conectar diretamente ao IP da sua VPS,"
        echo " ele conecta ao domínio da Vercel (CDN gratuito) que"
        echo " repassa o tráfego para sua VPS de forma transparente."
        echo ""
        echo -e " ${TXT_GREEN}Benefício:${RESET} Oculta o IP da VPS em redes com bloqueio de data centers."
        echo -e " ${TXT_GREEN}Custo:${RESET}     Gratuito (plano Hobby da Vercel)."
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
        _generate_relay_files "$vps_ip" "$vps_port" "$relay_path" "$out_dir"

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
        vercel_domain=$(echo "${vercel_domain:-}" | tr -d '[:space:][:cntrl:]' | sed 's|https://||')

        if [ -z "$vercel_domain" ]; then
            echo -e "${TXT_RED}❌ Domínio inválido.${RESET}"; sleep 2; continue
        fi

        echo ""
        echo -e "${TXT_YELLOW}Testando conectividade com o relay...${RESET}"
        if curl -fsSL --max-time 10 "https://${vercel_domain}/health" >/dev/null 2>&1 || \
           curl -fsSL --max-time 10 "https://${vercel_domain}/" >/dev/null 2>&1; then
            echo -e "${TXT_GREEN}✅ Relay acessível!${RESET}"
        else
            echo -e "${TXT_YELLOW}⚠  Não foi possível verificar o relay (normal se o path não responder a GET simples).${RESET}"
        fi

        echo ""
        echo -e "${TXT_YELLOW}PASSO 5 — Atualizando config do Xray para aceitar CDN...${RESET}"

        # Atualiza xhttpSettings para aceitar host do CDN
        tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
        if jq --arg cdnhost "$vercel_domain" \
            '(.inbounds[] | select(.tag=="inbound-turbonet") |
             .streamSettings.xhttpSettings) += {"host": $cdnhost}' \
            "$CONFIG_PATH" > "$tmp_cfg" 2>/dev/null && \
            jq empty "$tmp_cfg" 2>/dev/null; then
            cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
            mv -f "$tmp_cfg" "$CONFIG_PATH"
            _apply_config_perms
            echo -e "${TXT_GREEN}✅ Config atualizado.${RESET}"
        else
            rm -f "$tmp_cfg"
            echo -e "${TXT_YELLOW}⚠  Não foi possível atualizar o config automaticamente.${RESET}"
        fi

        # Salva informações do relay
        mkdir -p "$XRAYTOOLS_DIR"
        jq -n \
            --arg vps_ip    "$vps_ip" \
            --arg vps_port  "$vps_port" \
            --arg domain    "$vercel_domain" \
            --arg path      "$relay_path" \
            --arg created   "$(date '+%Y-%m-%d %H:%M:%S')" \
            '{vps_ip:$vps_ip,vps_port:$vps_port,vercel_domain:$domain,path:$path,created:$created}' \
            > "$RELAY_INFO_FILE"
        chmod 600 "$RELAY_INFO_FILE"

        # Gera link VLESS com domínio Vercel
        local_uuid=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet")
                            | .settings.clients[0].id // empty' \
                     "$CONFIG_PATH" 2>/dev/null || echo "")

        echo ""
        echo -e "${TXT_GREEN}=================================================${RESET}"
        echo -e "${TXT_GREEN}✅ RELAY VERCEL CONFIGURADO COM SUCESSO!${RESET}"
        echo -e "${TXT_GREEN}=================================================${RESET}"
        echo -e " Relay:  ${TXT_CYAN}https://${vercel_domain}${RESET}"
        echo -e " VPS:    ${TXT_CYAN}${vps_ip}:${vps_port}${RESET} (oculto)"
        if [ -n "$local_uuid" ]; then
            local_link="vless://${local_uuid}@${vercel_domain}:443?mode=auto&security=tls&encryption=none&type=xhttp&host=${vercel_domain}&path=%2F&sni=${vercel_domain}#XHTTP-CDN-TURBONET"
            echo ""
            echo -e " ${TXT_YELLOW}Link VLESS com CDN:${RESET}"
            echo -e " ${TXT_BLUE}${local_link}${RESET}"
            # Salva no conn_info
            echo "LINK_CDN=${local_link}" >> "$CONN_INFO_FILE" 2>/dev/null || true
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
        new_domain=$(echo "${new_domain:-}" | tr -d '[:space:][:cntrl:]' | sed 's|https://||')

        if [ -z "$new_domain" ]; then
            echo -e "${TXT_RED}❌ Domínio inválido.${RESET}"; sleep 2; continue
        fi

        if [ -f "$RELAY_INFO_FILE" ]; then
            old_domain=$(jq -r '.vercel_domain // ""' "$RELAY_INFO_FILE" 2>/dev/null || echo "")
            jq --arg d "$new_domain" '.vercel_domain = $d' "$RELAY_INFO_FILE" > "${RELAY_INFO_FILE}.tmp" && \
                mv -f "${RELAY_INFO_FILE}.tmp" "$RELAY_INFO_FILE"
            chmod 600 "$RELAY_INFO_FILE"
        fi

        # Atualiza xhttpSettings
        tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
        if jq --arg cdnhost "$new_domain" \
            '(.inbounds[] | select(.tag=="inbound-turbonet") |
             .streamSettings.xhttpSettings.host) = $cdnhost' \
            "$CONFIG_PATH" > "$tmp_cfg" 2>/dev/null && \
            jq empty "$tmp_cfg" 2>/dev/null; then
            cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
            mv -f "$tmp_cfg" "$CONFIG_PATH"
            _apply_config_perms
            echo -e "${TXT_GREEN}✅ Domínio atualizado para: ${new_domain}${RESET}"
        else
            rm -f "$tmp_cfg"
            echo -e "${TXT_RED}❌ Falha ao atualizar config.${RESET}"
        fi
        sleep 2
        ;;

    # ============================================================
    3)  # GERAR ARQUIVOS (sem configurar)
    # ============================================================
        vps_ip=$(_get_vps_ip)
        vps_port=$(_get_preset "port")
        [ -z "${vps_port:-}" ] && read -rp "Porta do Xray: " vps_port

        out_dir="/tmp/turbonet_vercel_relay"
        rm -rf "$out_dir"
        _generate_relay_files "${vps_ip:-SEU_IP}" "${vps_port:-443}" "/" "$out_dir"

        echo ""
        echo -e "${TXT_GREEN}✅ Arquivos gerados em: ${out_dir}/${RESET}"
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
        local_uuid=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet")
                            | .settings.clients[0].id // empty' \
                     "$CONFIG_PATH" 2>/dev/null || echo "")

        echo ""
        if [ -n "$local_uuid" ] && [ -n "$vercel_domain" ]; then
            local_link="vless://${local_uuid}@${vercel_domain}:443?mode=auto&security=tls&encryption=none&type=xhttp&host=${vercel_domain}&path=%2F&sni=${vercel_domain}#XHTTP-CDN-TURBONET"
            echo -e "${TXT_YELLOW}Link VLESS com CDN Vercel:${RESET}"
            echo -e "${TXT_BLUE}${local_link}${RESET}"
        else
            echo -e "${TXT_RED}❌ UUID ou domínio não encontrado.${RESET}"
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

        # Remove host do xhttpSettings
        tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
        if jq 'del(.inbounds[] | select(.tag=="inbound-turbonet") |
               .streamSettings.xhttpSettings.host)' \
            "$CONFIG_PATH" > "$tmp_cfg" 2>/dev/null && \
            jq empty "$tmp_cfg" 2>/dev/null; then
            cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
            mv -f "$tmp_cfg" "$CONFIG_PATH"
            _apply_config_perms
        else
            rm -f "$tmp_cfg"
        fi

        rm -f "$RELAY_INFO_FILE"
        echo -e "${TXT_GREEN}✅ Relay removido. Conexão voltou ao IP direto.${RESET}"
        sleep 2
        ;;

    0) exit 0 ;;
    *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
