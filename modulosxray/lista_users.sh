#!/bin/bash
# lista_users.sh - TURBONET XRAY V1.3
# Correções aplicadas V1.3:
#   - Array associativo em memória (USER_CFG_STATUS) com lookup O(1) — zero forks de jq por usuário
#   - _load_status_map() executado antes da listagem e das exportações CSV/JSON (elimina unbound variable)
#   - Exportação JSON gerada com jq (escape seguro de senhas e validação numérica)
#   - Permissões chmod 600 nos arquivos exportados em /tmp (protege UUIDs e senhas)
#   - Alinhamento do cálculo de vencimento para considerar o dia inteiro da expiração
#   - Removido prompt duplicado de Enter após exportação

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"

TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_YELLOW='\033[1;33m'
TXT_CYAN='\033[1;36m'
TXT_DIM='\033[2m'
RESET='\033[0m'

WARN_DAYS=7
export DEBIAN_FRONTEND=noninteractive

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
fi

# --- DEPENDÊNCIA JQ ---
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
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >/dev/null 2>&1 || true; _APT_UPDATED=1; }
            apt-get install -y "$pkg" >/dev/null 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >/dev/null 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >/dev/null 2>&1 ;;
    esac
}

ensure_cmd jq jq

mkdir -p "$(dirname "$USER_DB")"
touch "$USER_DB"
chmod 600 "$USER_DB"

# --- HELPERS DE DATA ---
_today_midnight_ts() {
    date -d "$(date +%F)" +%s
}

is_expired() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 1
    today_ts=$(_today_midnight_ts)
    [ "$exp_ts" -lt "$today_ts" ]
}

expires_soon() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    local exp_ts warn_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 1
    today_ts=$(_today_midnight_ts)
    warn_ts=$(( today_ts + WARN_DAYS * 86400 ))
    [ "$exp_ts" -ge "$today_ts" ] && [ "$exp_ts" -le "$warn_ts" ]
}

days_remaining() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "-999"; return; }
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || { echo "-999"; return; }
    today_ts=$(_today_midnight_ts)
    echo $(( (exp_ts - today_ts) / 86400 ))
}

# --- PRÉ-CARREGAMENTO DO STATUS DO CONFIG EM MEMÓRIA (O(1)) ---
declare -A USER_CFG_STATUS

_load_status_map() {
    USER_CFG_STATUS=()
    [ -s "$CONFIG_PATH" ] || return 0
    jq empty "$CONFIG_PATH" 2>/dev/null || return 0

    local email state
    while IFS='|' read -r email state; do
        [ -n "${email:-}" ] || continue
        USER_CFG_STATUS["$email"]="$state"
    done < <(jq -r '
        .inbounds[]?
        | select(.tag=="inbound-turbonet")
        | .settings.clients[]?
        | select(.email?)
        | "\(.email)|\(if (.email | startswith("LOCKED_")) then "locked" else "active" end)"
    ' "$CONFIG_PATH" 2>/dev/null || true)
}

get_config_status() {
    local nick="$1"
    local locked_key="LOCKED_${nick}"

    if [ "${USER_CFG_STATUS[$locked_key]:-}" = "locked" ]; then
        echo "locked"
    elif [ "${USER_CFG_STATUS[$nick]:-}" = "active" ]; then
        echo "active"
    else
        echo "unknown"
    fi
}

# --- EXPORTAÇÃO ---
export_to_csv() {
    _load_status_map
    local output_file="/tmp/lista_users_$(date +%Y%m%d_%H%M%S).csv"
    install -m 600 /dev/null "$output_file"
    echo "USERNAME,UUID,EXPIRY,DAYS_REMAINING,CONNECTION_LIMIT,PASSWORD,STATUS" > "$output_file"

    while IFS='|' read -r nick uuid expiry password conn_limit _rest; do
        nick="${nick//$'\r'/}"
        uuid="${uuid//$'\r'/}"
        expiry="${expiry//$'\r'/}"
        password="${password//$'\r'/}"
        conn_limit="${conn_limit//$'\r'/}"

        [ -n "${nick:-}" ] && [ -n "${uuid:-}" ] || continue

        local days cfg_status status conn_display
        days=$(days_remaining "${expiry:-}")
        [ "$days" = "-999" ] && days="?"
        cfg_status=$(get_config_status "$nick")

        if [ "$cfg_status" = "locked" ]; then
            status="BLOQUEADO"
        elif is_expired "${expiry:-}"; then
            status="EXPIRADO"
        elif [ "$cfg_status" = "unknown" ]; then
            status="FORA_DE_SYNC"
        elif expires_soon "${expiry:-}"; then
            status="EXPIRA_EM_BREVE"
        else
            status="ATIVO"
        fi

        if ! [[ "${conn_limit:-0}" =~ ^[0-9]+$ ]] || [ "${conn_limit:-0}" -eq 0 ]; then
            conn_display="Ilimitado"
        else
            conn_display="${conn_limit}"
        fi

        # Escapa aspas duplas internas conforme RFC 4180
        local safe_pass="${password//\"/\"\"}"
        echo "\"${nick}\",\"${uuid}\",\"${expiry:-}\",\"${days}\",\"${conn_display}\",\"${safe_pass:-N/A}\",\"${status}\"" >> "$output_file"
    done < "$USER_DB"

    chmod 600 "$output_file"
    echo "$output_file"
}

export_to_json() {
    _load_status_map
    local output_file="/tmp/lista_users_$(date +%Y%m%d_%H%M%S).json"
    install -m 600 /dev/null "$output_file"

    local tmp_ndjson
    tmp_ndjson=$(mktemp /tmp/lista_users_ndjson_XXXXXX)

    while IFS='|' read -r nick uuid expiry password conn_limit _rest; do
        nick="${nick//$'\r'/}"
        uuid="${uuid//$'\r'/}"
        expiry="${expiry//$'\r'/}"
        password="${password//$'\r'/}"
        conn_limit="${conn_limit//$'\r'/}"

        [ -n "${nick:-}" ] && [ -n "${uuid:-}" ] || continue

        local days cfg_status status
        days=$(days_remaining "${expiry:-}")
        [[ "$days" =~ ^-?[0-9]+$ ]] || days=-999
        [[ "${conn_limit:-0}" =~ ^[0-9]+$ ]] || conn_limit=0
        cfg_status=$(get_config_status "$nick")

        if [ "$cfg_status" = "locked" ]; then
            status="BLOQUEADO"
        elif is_expired "${expiry:-}"; then
            status="EXPIRADO"
        elif [ "$cfg_status" = "unknown" ]; then
            status="FORA_DE_SYNC"
        elif expires_soon "${expiry:-}"; then
            status="EXPIRA_EM_BREVE"
        else
            status="ATIVO"
        fi

        jq -n -c \
            --arg username "$nick" \
            --arg uuid "$uuid" \
            --arg expiry "${expiry:-}" \
            --argjson days_remaining "$days" \
            --argjson connection_limit "$conn_limit" \
            --arg password "${password:-}" \
            --arg status "$status" \
            '{
                username: $username,
                uuid: $uuid,
                expiry: $expiry,
                days_remaining: $days_remaining,
                connection_limit: $connection_limit,
                password: $password,
                status: $status
            }' >> "$tmp_ndjson"
    done < "$USER_DB"

    jq -s '.' "$tmp_ndjson" > "$output_file"
    rm -f "$tmp_ndjson"
    chmod 600 "$output_file"
    echo "$output_file"
}

# --- INTERFACE ---
mostrar_menu_filtro() {
    clear
    echo -e "${TITLE_BAR}   LISTA DE USUÁRIOS - FILTRO   ${RESET}"
    echo ""
    echo "Selecione o filtro:"
    echo ""
    echo -e "  [1] ${TXT_CYAN}Todos os usuários${RESET}"
    echo -e "  [2] ${TXT_GREEN}Apenas Ativos${RESET}"
    echo -e "  [3] ${TXT_YELLOW}Expirando em breve${RESET}"
    echo -e "  [4] ${TXT_RED}Bloqueados${RESET}"
    echo -e "  [5] ${TXT_RED}Expirados${RESET}"
    echo -e "  [6] ${TXT_YELLOW}Fora de Sync${RESET}"
    echo ""
    echo -e "  [7] ${TXT_CYAN}Exportar para CSV${RESET}"
    echo -e "  [8] ${TXT_CYAN}Exportar para JSON${RESET}"
    echo ""
    echo -e "  [0] ${TXT_DIM}Voltar${RESET}"
    echo ""
}

mostrar_lista() {
    local filter="$1"

    _load_status_map

    clear
    echo -e "${TITLE_BAR}   LISTA DE USUÁRIOS   ${RESET}"

    printf "%-12s | %-19s | %-12s | %-5s | %-8s | %s\n" \
        "USUÁRIO" "UUID" "EXPIRA" "DIAS" "CONN" "STATUS"
    echo "---------------------------------------------------------------------------------------------------"

    local count_total=0
    local count_active=0
    local count_locked=0
    local count_expired=0
    local count_warn=0
    local count_unknown=0
    local count_shown=0

    while IFS='|' read -r nick uuid expiry password conn_limit _rest; do
        nick="${nick//$'\r'/}"
        uuid="${uuid//$'\r'/}"
        expiry="${expiry//$'\r'/}"
        password="${password//$'\r'/}"
        conn_limit="${conn_limit//$'\r'/}"

        [ -n "${nick:-}" ] && [ -n "${uuid:-}" ] || continue

        local uuid_short="${uuid:0:8}...${uuid: -4}"
        local local_expired=false
        local local_soon=false
        local days=-999

        if [[ "${expiry:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            days=$(days_remaining "$expiry")
            is_expired "$expiry"   && local_expired=true || true
            expires_soon "$expiry" && local_soon=true    || true
        fi

        local cfg_status
        cfg_status=$(get_config_status "$nick")

        local local_color="$RESET"
        local status_label=""
        local should_show=false

        if [ "$cfg_status" = "locked" ]; then
            local_color="$TXT_RED"
            status_label="${TXT_RED}BLOQUEADO${RESET}"
            count_locked=$(( count_locked + 1 ))
            { [ "$filter" = "locked" ] || [ "$filter" = "all" ]; } && should_show=true
        elif [ "$local_expired" = true ]; then
            local_color="$TXT_DIM"
            status_label="${TXT_RED}EXPIRADO${RESET}"
            count_expired=$(( count_expired + 1 ))
            { [ "$filter" = "expired" ] || [ "$filter" = "all" ]; } && should_show=true
        elif [ "$cfg_status" = "unknown" ]; then
            local_color="$TXT_YELLOW"
            status_label="${TXT_YELLOW}FORA DE SYNC${RESET}"
            count_unknown=$(( count_unknown + 1 ))
            count_active=$(( count_active + 1 ))
            { [ "$filter" = "sync" ] || [ "$filter" = "all" ]; } && should_show=true
        elif [ "$local_soon" = true ]; then
            local_color="$TXT_YELLOW"
            status_label="${TXT_YELLOW}EXPIRA EM BREVE${RESET}"
            count_warn=$(( count_warn + 1 ))
            count_active=$(( count_active + 1 ))
            { [ "$filter" = "warn" ] || [ "$filter" = "active" ] || [ "$filter" = "all" ]; } && should_show=true
        else
            local_color="$TXT_GREEN"
            status_label="${TXT_GREEN}ATIVO${RESET}"
            count_active=$(( count_active + 1 ))
            { [ "$filter" = "active" ] || [ "$filter" = "all" ]; } && should_show=true
        fi

        local days_display="$days"
        [ "$days" = "-999" ] && days_display="?"

        local conn_display
        if ! [[ "${conn_limit:-0}" =~ ^[0-9]+$ ]] || [ "${conn_limit:-0}" -eq 0 ]; then
            conn_display="${TXT_DIM}∞${RESET}"
        else
            conn_display="${conn_limit}"
        fi

        local pwd_display=""
        if [ -n "${password:-}" ]; then
            pwd_display=" ${TXT_CYAN}[${password}]${RESET}"
        fi

        if [ "$should_show" = true ]; then
            printf "${local_color}%-12s${RESET} | ${local_color}%-19s${RESET} | ${local_color}%-12s${RESET} | ${local_color}%-5s${RESET} | ${local_color}%-8s${RESET} | %b%b\n" \
                "$nick" "$uuid_short" "${expiry:-sem data}" "$days_display" "$conn_display" "$status_label" "$pwd_display"
            count_shown=$(( count_shown + 1 ))
        fi

        count_total=$(( count_total + 1 ))
    done < "$USER_DB"

    echo "---------------------------------------------------------------------------------------------------"
    echo ""
    echo -e " Mostrando: ${TXT_CYAN}${count_shown}${RESET} de ${count_total} usuários"
    echo ""
    echo -e " Resumo:"
    echo -e "   Total:         ${TXT_CYAN}${count_total}${RESET}"
    echo -e "   Ativos:        ${TXT_GREEN}${count_active}${RESET}"
    [ "$count_warn"    -gt 0 ] && echo -e "   ↳ Expirando:   ${TXT_YELLOW}${count_warn}${RESET}"
    [ "$count_unknown" -gt 0 ] && echo -e "   ↳ ForadeSync:  ${TXT_YELLOW}${count_unknown}${RESET}"
    [ "$count_locked"  -gt 0 ] && echo -e "   Bloqueados:    ${TXT_RED}${count_locked}${RESET}"
    [ "$count_expired" -gt 0 ] && echo -e "   Expirados:     ${TXT_RED}${count_expired}${RESET}"
    echo ""
}

# Loop principal
while true; do
    mostrar_menu_filtro
    read -rp "Opção: " option

    case "${option:-0}" in
        1) mostrar_lista "all";     read -rp "Pressione Enter para voltar ao menu..." ;;
        2) mostrar_lista "active";  read -rp "Pressione Enter para voltar ao menu..." ;;
        3) mostrar_lista "warn";    read -rp "Pressione Enter para voltar ao menu..." ;;
        4) mostrar_lista "locked";  read -rp "Pressione Enter para voltar ao menu..." ;;
        5) mostrar_lista "expired"; read -rp "Pressione Enter para voltar ao menu..." ;;
        6) mostrar_lista "sync";    read -rp "Pressione Enter para voltar ao menu..." ;;
        7)
            echo ""
            echo -e "${TXT_CYAN}Exportando para CSV...${RESET}"
            csv_file=$(export_to_csv)
            echo -e "${TXT_GREEN}✅ Exportado para: ${csv_file} (permissão 600)${RESET}"
            echo ""
            read -rp "Pressione Enter para voltar ao menu..."
            ;;
        8)
            echo ""
            echo -e "${TXT_CYAN}Exportando para JSON...${RESET}"
            json_file=$(export_to_json)
            echo -e "${TXT_GREEN}✅ Exportado para: ${json_file} (permissão 600)${RESET}"
            echo ""
            read -rp "Pressione Enter para voltar ao menu..."
            ;;
        0) exit 0 ;;
        *)
            echo -e "${TXT_RED}❌ Opção inválida${RESET}"
            sleep 1
            ;;
    esac
done
