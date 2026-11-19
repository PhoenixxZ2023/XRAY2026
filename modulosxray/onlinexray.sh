#!/bin/bash
# onlinexray.sh - TURBONET XRAY V1.1
# Correções aplicadas:
#   - Consulta única por ciclo via `xray api statsquery` + jq (elimina aspas do protojson e gargalo 2xN)
#   - Sanitização estrita de inteiros antes da aritmética Bash sob set -Eeuo pipefail
#   - Baseline inicial sem falso positivo de "Online" para tráfego antigo acumulado
#   - Atualização dinâmica da lista de usuários ativos a cada 5 ciclos
#   - Detecção da porta API por tag "api" ou protocolo "dokodemo-door" com fallback 1080

set -Eeuo pipefail
trap 'echo -e "\n\033[1;33mSaindo...\033[0m"; exit 0' INT TERM

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
DIM='\033[2m'
RESET='\033[0m'

CONF="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
WINDOW=15
SLEEP=3
API_TIMEOUT=3

export DEBIAN_FRONTEND=noninteractive

# --- VERIFICAÇÃO DE ROOT ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${RED}❌ Execute como root!${RESET}"
    exit 1
fi

# --- DETECÇÃO DE DISTRO ---
_PKG_MANAGER=""
_APT_UPDATED=0
_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else echo -e "${RED}❌ Gerenciador de pacotes não detectado.${RESET}"; exit 1; fi
}

ensure_cmd() {
    local cmd="$1" pkg="$2"
    command -v "$cmd" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >/dev/null 2>&1 || true; _APT_UPDATED=1; }
            apt-get install -y "$pkg" >/dev/null 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >/dev/null 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >/dev/null 2>&1 ;;
    esac
}

ensure_cmd jq jq

# --- PRÉ-CONDIÇÕES ---
if [ ! -s "$CONF" ]; then
    echo -e "${RED}❌ config.json não encontrado.${RESET}"; exit 1
fi
if ! jq empty "$CONF" 2>/dev/null; then
    echo -e "${RED}❌ config.json inválido.${RESET}"; exit 1
fi
if [ ! -x "$XRAY_BIN" ]; then
    echo -e "${RED}❌ xray não encontrado em $XRAY_BIN.${RESET}"; exit 1
fi
if ! jq -e '.inbounds[]? | select(.tag=="api" or .protocol=="dokodemo-door")' "$CONF" >/dev/null 2>&1; then
    echo -e "${RED}❌ Inbound API não configurado no Xray.${RESET}"; exit 1
fi

API_PORT="$(jq -r '.inbounds[]? | select(.tag=="api" or .protocol=="dokodemo-door") | .port // empty' "$CONF" 2>/dev/null | head -1 || true)"
[ -n "${API_PORT:-}" ] || API_PORT="1080"

# --- CARREGA USUÁRIOS ATIVOS (sem LOCKED_) ---
USERS=()
_load_users() {
    mapfile -t USERS < <(jq -r '
        .inbounds[]? | select(.tag=="inbound-turbonet")
        | .settings.clients[]?
        | select(.email? and (.email | startswith("LOCKED_") | not))
        | .email
    ' "$CONF" 2>/dev/null | awk 'NF')
}

_load_users
if [ ${#USERS[@]} -eq 0 ]; then
    echo -e "${RED}Nenhum usuário ativo no inbound-turbonet.${RESET}"; exit 0
fi

# --- CONSULTA ÚNICA À API POR CICLO ---
declare -A cur_down cur_up last_down last_up last_seen delta_total

_poll_all_stats() {
    cur_down=()
    cur_up=()

    local raw
    raw=$(timeout "$API_TIMEOUT" "$XRAY_BIN" api statsquery \
        -server="127.0.0.1:${API_PORT}" \
        -pattern "user>>>" 2>/dev/null || echo "{}")

    local stat_name stat_val u
    while IFS='|' read -r stat_name stat_val; do
        [ -n "${stat_name:-}" ] || continue
        [[ "${stat_val:-}" =~ ^[0-9]+$ ]] || stat_val=0
        case "$stat_name" in
            *">>>traffic>>>downlink")
                u="${stat_name#user>>>}"
                u="${u%>>>traffic>>>downlink}"
                cur_down["$u"]="$stat_val"
                ;;
            *">>>traffic>>>uplink")
                u="${stat_name#user>>>}"
                u="${u%>>>traffic>>>uplink}"
                cur_up["$u"]="$stat_val"
                ;;
        esac
    done < <(echo "$raw" | jq -r '
        .stat[]? |
        select(.name? and (.name | test("^user>>>[^>]+>>>traffic>>>(downlink|uplink)$"))) |
        "\(.name)|\(.value // 0 | tostring | gsub("[^0-9]"; ""))"
    ' 2>/dev/null || true)
}

bytes_human() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN {
        if      (b >= 1073741824) printf "%.1f GB\n", b/1073741824
        else if (b >= 1048576)    printf "%.1f MB\n", b/1048576
        else if (b >= 1024)       printf "%.1f KB\n", b/1024
        else                      printf "%d B\n",    b
    }'
}

# --- BASELINE INICIAL ---
echo -e "${CYAN}Inicializando monitor para ${#USERS[@]} usuário(s)...${RESET}"
_poll_all_stats
for u in "${USERS[@]}"; do
    last_down["$u"]="${cur_down["$u"]:-0}"
    last_up["$u"]="${cur_up["$u"]:-0}"
    last_seen["$u"]=0
done

sleep 1

xray_ok=true
cycle=0

# --- LOOP PRINCIPAL ---
while true; do
    now="$(date +%s)"
    cycle=$(( cycle + 1 ))

    if (( cycle % 5 == 1 )); then
        systemctl is-active --quiet xray 2>/dev/null && xray_ok=true || xray_ok=false
        _load_users
    fi

    _poll_all_stats

    for u in "${USERS[@]}"; do
        d="${cur_down["$u"]:-0}"
        up="${cur_up["$u"]:-0}"
        prev_d="${last_down["$u"]:-0}"
        prev_u="${last_up["$u"]:-0}"

        dd=$(( d  - prev_d ))
        du=$(( up - prev_u ))
        [ "$dd" -lt 0 ] && dd="$d"
        [ "$du" -lt 0 ] && du="$up"

        dt=$(( dd + du ))
        delta_total["$u"]="$dt"

        if [ "$dt" -gt 0 ]; then
            last_seen["$u"]="$now"
        fi

        last_down["$u"]="$d"
        last_up["$u"]="$up"
    done

    # Renderiza tela
    clear
    echo -e "${CYAN}================================================${RESET}"
    echo -e "${CYAN}      MONITOR DE USUÁRIOS ONLINE (API)         ${RESET}"
    echo -e "${CYAN}================================================${RESET}"
    echo -e " Janela: ${YELLOW}${WINDOW}s${RESET}  Poll: ${YELLOW}${SLEEP}s${RESET}  Timeout API: ${YELLOW}${API_TIMEOUT}s${RESET}  Ciclo: ${DIM}#${cycle}${RESET}"

    if [ "$xray_ok" = false ]; then
        echo -e " ${RED}⚠  Xray não está ativo — stats podem estar zeradas!${RESET}"
    fi

    echo -e " Hora: $(date '+%H:%M:%S')  Usuários monitorados: ${#USERS[@]}"
    echo -e "${CYAN}------------------------------------------------${RESET}"
    printf " ${CYAN}%-14s${RESET} | ${CYAN}%-12s${RESET} | ${CYAN}%s${RESET}\n" "USUÁRIO" "DELTA CICLO" "STATUS"
    echo -e "${CYAN}------------------------------------------------${RESET}"

    online_count=0
    for u in "${USERS[@]}"; do
        seen="${last_seen["$u"]:-0}"
        age=$(( now - seen ))
        dt="${delta_total["$u"]:-0}"

        if [ "$seen" -gt 0 ] && [ "$age" -le "$WINDOW" ]; then
            delta_h="$(bytes_human "$dt")"
            printf " ${GREEN}%-14s${RESET} | ${YELLOW}%-12s${RESET} | ${GREEN}● Online${RESET} ${DIM}(há ${age}s)${RESET}\n" \
                "$u" "$delta_h"
            online_count=$(( online_count + 1 ))
        else
            if [ "$seen" -gt 0 ]; then
                printf " ${DIM}%-14s${RESET} | ${DIM}%-12s${RESET} | ${DIM}○ Inativo (há ${age}s)${RESET}\n" \
                    "$u" "-"
            else
                printf " ${DIM}%-14s${RESET} | ${DIM}%-12s${RESET} | ${DIM}○ Sem atividade${RESET}\n" \
                    "$u" "-"
            fi
        fi
    done

    echo -e "${CYAN}------------------------------------------------${RESET}"
    if [ "$online_count" -eq 0 ]; then
        echo -e " ${RED}Nenhum usuário ativo na janela de ${WINDOW}s.${RESET}"
    else
        echo -e " ${GREEN}${online_count} usuário(s) online agora.${RESET}"
    fi
    echo -e "${CYAN}================================================${RESET}"
    echo -e " ${DIM}CTRL+C para sair${RESET}"

    sleep "$SLEEP"
done
