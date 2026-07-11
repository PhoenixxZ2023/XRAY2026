#!/bin/bash
# lista_users.sh - TURBONET XRAY V1.2
# Correções aplicadas:
#   - set -Eeuo pipefail — consistente com demais módulos
#   - Status do config.json pré-carregado em um único jq antes do loop (O(1) vs O(2n))
#   - Status "unknown" exibido como "FORA DE SYNC" em amarelo
#   - Lookup normalizado para minúsculas
#   - Resumo com subcontagem explícita de "expirando" dentro dos ativos
#   - days_remaining() retorna sentinela numérico -999
#   - V1.2: Mostra limite de conexões na tabela
#   - V1.2: Mostra senha do CheckUser
#   - V1.2: Filtro interativo (todos/ativos/expirados/bloqueados)
#   - V1.2: Exportar para CSV/JSON
#
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

mkdir -p "$(dirname "$USER_DB")"
touch "$USER_DB"

# --- HELPERS DE DATA ---
is_expired() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 1
    today_ts=$(date +%s)
    [ "$exp_ts" -lt "$today_ts" ]
}

expires_soon() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    local exp_ts warn_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 1
    today_ts=$(date +%s)
    warn_ts=$(( today_ts + WARN_DAYS * 86400 ))
    [ "$exp_ts" -ge "$today_ts" ] && [ "$exp_ts" -le "$warn_ts" ]
}

days_remaining() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "-999"; return; }
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || { echo "-999"; return; }
    today_ts=$(date +%s)
    echo $(( (exp_ts - today_ts) / 86400 ))
}

# --- PRÉ-CARREGAMENTO DO STATUS DO CONFIG ---
_build_status_map() {
    if [ ! -s "$CONFIG_PATH" ]; then echo '{}'; return; fi
    if ! jq empty "$CONFIG_PATH" 2>/dev/null; then echo '{}'; return; fi
    jq -c '
        [ .inbounds[]?
          | select(.tag=="inbound-turbonet")
          | .settings.clients[]?
          | select(.email?)
          | { key: .email,
              value: (if (.email | startswith("LOCKED_")) then "locked" else "active" end) }
        ] | from_entries
    ' "$CONFIG_PATH" 2>/dev/null || echo '{}'
}

get_config_status() {
    local nick="$1"
    local locked_key="LOCKED_${nick}"

    if jq -e --arg k "$locked_key" 'has($k)' <<< "$STATUS_MAP" >/dev/null 2>&1; then
        echo "locked"
    elif jq -e --arg k "$nick" 'has($k)' <<< "$STATUS_MAP" >/dev/null 2>&1; then
        echo "active"
    else
        echo "unknown"
    fi
}

# --- EXPORTAÇÃO ---
export_to_csv() {
    local output_file="/tmp/lista_users_$(date +%Y%m%d_%H%M%S).csv"
    echo "USERNAME,UUID,EXPIRY,DAYS_REMAINING,CONNECTION_LIMIT,PASSWORD,STATUS" > "$output_file"

    while IFS='|' read -r nick uuid expiry password conn_limit; do
        [ -n "${nick:-}" ] || continue
        [ -n "${uuid:-}" ] || continue

        days=$(days_remaining "$expiry" 2>/dev/null || echo "?")
        cfg_status=$(get_config_status "$nick" 2>/dev/null || echo "unknown")

        if [ "$cfg_status" = "locked" ]; then
            status="BLOQUEADO"
        elif is_expired "$expiry" 2>/dev/null; then
            status="EXPIRADO"
        elif [ "$cfg_status" = "unknown" ]; then
            status="FORA_DE_SYNC"
        elif expires_soon "$expiry" 2>/dev/null; then
            status="EXPIRA_EM_BREVE"
        else
            status="ATIVO"
        fi

        # Limite: 0 = Ilimitado
        if [ "${conn_limit:-0}" = "0" ] || [ -z "${conn_limit:-}" ]; then
            conn_display="Ilimitado"
        else
            conn_display="${conn_limit}"
        fi

        echo "\"${nick}\",\"${uuid}\",\"${expiry}\",\"${days}\",\"${conn_display}\",\"${password:-N/A}\",\"${status}\"" >> "$output_file"
    done < "$USER_DB"

    echo "$output_file"
}

export_to_json() {
    local output_file="/tmp/lista_users_$(date +%Y%m%d_%H%M%S).json"
    echo "[" > "$output_file"

    local first=true
    while IFS='|' read -r nick uuid expiry password conn_limit; do
        [ -n "${nick:-}" ] || continue
        [ -n "${uuid:-}" ] || continue

        days=$(days_remaining "$expiry" 2>/dev/null || echo "?")
        cfg_status=$(get_config_status "$nick" 2>/dev/null || echo "unknown")

        if [ "$cfg_status" = "locked" ]; then
            status="BLOQUEADO"
        elif is_expired "$expiry" 2>/dev/null; then
            status="EXPIRADO"
        elif [ "$cfg_status" = "unknown" ]; then
            status="FORA_DE_SYNC"
        elif expires_soon "$expiry" 2>/dev/null; then
            status="EXPIRA_EM_BREVE"
        else
            status="ATIVO"
        fi

        [ "$first" = true ] && first=false || echo "," >> "$output_file"

        cat >> "$output_file" <<EOF
  {
    "username": "${nick}",
    "uuid": "${uuid}",
    "expiry": "${expiry}",
    "days_remaining": ${days},
    "connection_limit": ${conn_limit:-0},
    "password": "${password:-}",
    "status": "${status}"
  }
EOF
    done < "$USER_DB"

    echo "]" >> "$output_file"
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

    # Carrega mapa de status uma única vez
    STATUS_MAP=$(_build_status_map)

    clear
    echo -e "${TITLE_BAR}   LISTA DE USUÁRIOS   ${RESET}"

    # Cabeçalho com colunas extras
    printf "%-12s | %-19s | %-12s | %-5s | %-8s | %s\n" \
        "USUÁRIO" "UUID" "EXPIRA" "DIAS" "CONN" "STATUS"
    echo "---------------------------------------------------------------------------------------------------"

    count_total=0
    count_active=0
    count_locked=0
    count_expired=0
    count_warn=0
    count_unknown=0
    count_shown=0

    while IFS='|' read -r nick uuid expiry password conn_limit; do
        [ -n "${nick:-}" ] || continue
        [ -n "${uuid:-}" ] || continue

        uuid_short="${uuid:0:8}...${uuid: -4}"

        local_expired=false
        local_soon=false
        days=-999
        if [[ "${expiry:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            days=$(days_remaining "$expiry")
            is_expired "$expiry"   && local_expired=true || true
            expires_soon "$expiry" && local_soon=true    || true
        fi

        cfg_status=$(get_config_status "$nick")

        # Monta cor e label de status
        local_color="$RESET"
        status_label=""

        should_show=false

        if [ "$cfg_status" = "locked" ]; then
            local_color="$TXT_RED"
            status_label="${TXT_RED}BLOQUEADO${RESET}"
            count_locked=$(( count_locked + 1 ))
            [ "$filter" = "locked" ] || [ "$filter" = "all" ] && should_show=true
        elif [ "$local_expired" = true ]; then
            local_color="$TXT_DIM"
            status_label="${TXT_RED}EXPIRADO${RESET}"
            count_expired=$(( count_expired + 1 ))
            [ "$filter" = "expired" ] || [ "$filter" = "all" ] && should_show=true
        elif [ "$cfg_status" = "unknown" ]; then
            local_color="$TXT_YELLOW"
            status_label="${TXT_YELLOW}FORA DE SYNC${RESET}"
            count_unknown=$(( count_unknown + 1 ))
            count_active=$(( count_active + 1 ))
            [ "$filter" = "sync" ] || [ "$filter" = "all" ] && should_show=true
        elif [ "$local_soon" = true ]; then
            local_color="$TXT_YELLOW"
            status_label="${TXT_YELLOW}EXPIRA EM BREVE${RESET}"
            count_warn=$(( count_warn + 1 ))
            count_active=$(( count_active + 1 ))
            [ "$filter" = "warn" ] || [ "$filter" = "active" ] || [ "$filter" = "all" ] && should_show=true
        else
            local_color="$TXT_GREEN"
            status_label="${TXT_GREEN}ATIVO${RESET}"
            count_active=$(( count_active + 1 ))
            [ "$filter" = "active" ] || [ "$filter" = "all" ] && should_show=true
        fi

        # Exibe dias: sentinela -999 vira "?" na saída visual
        days_display="$days"
        [ "$days" = "-999" ] && days_display="?"

        # Limite de conexões: 0 = Ilimitado
        if [ "${conn_limit:-0}" = "0" ] || [ -z "${conn_limit:-}" ]; then
            conn_display="${TXT_DIM}∞${RESET}"
        else
            conn_display="${conn_limit}"
        fi

        # Mostra a senha (se existir no DB)
        if [ -n "${password:-}" ]; then
            pwd_display=" ${TXT_CYAN}[${password}]${RESET}"
        else
            pwd_display=""
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
    echo -e "   Total:          ${TXT_CYAN}${count_total}${RESET}"
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

    case "$option" in
        1) mostrar_lista "all" ;;
        2) mostrar_lista "active" ;;
        3) mostrar_lista "warn" ;;
        4) mostrar_lista "locked" ;;
        5) mostrar_lista "expired" ;;
        6) mostrar_lista "sync" ;;
        7)
            echo ""
            echo -e "${TXT_CYAN}Exportando para CSV...${RESET}"
            csv_file=$(export_to_csv)
            echo -e "${TXT_GREEN}✅ Exportado para: ${csv_file}${RESET}"
            echo ""
            read -rp "Enter para continuar..."
            ;;
        8)
            echo ""
            echo -e "${TXT_CYAN}Exportando para JSON...${RESET}"
            json_file=$(export_to_json)
            echo -e "${TXT_GREEN}✅ Exportado para: ${json_file}${RESET}"
            echo ""
            read -rp "Enter para continuar..."
            ;;
        0) exit 0 ;;
        *)
            echo -e "${TXT_RED}❌ Opção inválida${RESET}"
            sleep 1
            ;;
    esac
    read -rp "Pressione Enter para voltar ao menu..."
done
