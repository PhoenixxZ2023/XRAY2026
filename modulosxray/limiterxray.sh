#!/bin/bash
# limiterxray.sh - TURBONET XRAY V1.5 (PRO + Hot-Reload API + Compatibilidade Bot Telegram)
# Atualizações V1.5:
# - _apply_config_perms e _apply_xraytools_perms preservam permissões 2770/0660 quando o usuário `botxray` existe
# - Corrigida sintaxe da API interna (`xray api removeuser -email=...` + `xray api adduser`) para bloquear/desbloquear sem reiniciar o Xray
# - Fallback automático para `systemctl restart xray` apenas se a API interna estiver indisponível
# - Bloqueio/desbloqueio completo da conta Linux (`usermod`, `chage`, `passwd`) com proteção para contas do sistema (UID < 1000)
# - Verificação explícita de execução como root (EUID)

set -Eeuo pipefail

# ================================================================
# CLEANUP CENTRALIZADO
# ================================================================
_TMP_FILES=()
_cleanup() {
    for f in "${_TMP_FILES[@]:-}"; do
        [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
    done
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

XRAY_BIN="/usr/local/bin/xray"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
XRAYTOOLS_DIR="/opt/XrayTools"
LIMITS_DB="${XRAYTOOLS_DIR}/limits.db"
USAGE_DB="${XRAYTOOLS_DIR}/usage.db"
SESSION_DB="${XRAYTOOLS_DIR}/session.db"
USER_DB="${XRAYTOOLS_DIR}/users.db"
LOG_FILE="/tmp/limiterxray.log"
LOCK_FILE="/tmp/limiterxray.lock"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

XRAY_API_PORT_DEFAULT="1080"
XRAY_API_PORT=""
XRAY_API_TIMEOUT=5

TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    [ "${1:-}" != "--cron" ] && echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
fi

# ================================================================
# DETECÇÃO AUTOMÁTICA DE PORTA API
# ================================================================
_detect_api_port() {
    local detected_port=""

    if [ -f "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null; then
        detected_port=$(jq -r '.inbounds[]? | select(.tag=="api" or .protocol=="dokodemo-door") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1)
    fi

    if [ -n "${detected_port:-}" ] && [[ "$detected_port" =~ ^[0-9]+$ ]]; then
        XRAY_API_PORT="$detected_port"
        return 0
    fi

    XRAY_API_PORT="$XRAY_API_PORT_DEFAULT"
    return 1
}

# ================================================================
# DETECÇÃO DE DISTRO
# ================================================================
_PKG_MANAGER=""
_APT_UPDATED=0

_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman &>/dev/null; then _PKG_MANAGER="pacman"
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
        pacman) pacman -Sy --noconfirm "$pkg" >>"$LOG_FILE" 2>&1 ;;
    esac
}

validate_nick() {
    local n="${1:-}"
    [[ "$n" =~ ^[a-zA-Z0-9]{5,9}$ ]]
}

# ================================================================
# UUID COM FALLBACK
# ================================================================
generate_uuid() {
    local u=""
    if command -v uuidgen &>/dev/null; then
        u=$(uuidgen | tr '[:upper:]' '[:lower:]')
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        u=$(cat /proc/sys/kernel/random/uuid)
    else
        u=$(od -x /dev/urandom | head -1 | \
            awk '{printf "%s%s-%s-4%s-%s%s-%s%s\n",$2,$3,$4,substr($5,2),substr($6,1,1),substr($6,2),$7,$8}' | \
            tr '[:upper:]' '[:lower:]')
    fi
    [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
        echo -e "${TXT_RED}❌ Falha ao gerar UUID.${RESET}" >&2; return 1
    }
    echo "$u"
}

# ================================================================
# LOCK EXCLUSIVO (evita race condition cron vs UI)
# ================================================================
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        [ "${1:-}" != "--cron" ] && echo -e "${TXT_RED}⚠ Outra instância do limiter está rodando. Aguarde.${RESET}"
        exit 1
    fi
}

release_lock() { flock -u 9 2>/dev/null || true; rm -f "$LOCK_FILE"; }

# ================================================================
# DETECÇÃO DINÂMICA DE DONO, PERMISSÕES E VALIDAÇÃO DO CONFIG
# ================================================================
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

_apply_xraytools_perms() {
    mkdir -p "$XRAYTOOLS_DIR"
    if id -u botxray &>/dev/null; then
        chown root:botxray "$XRAYTOOLS_DIR"
        chmod 2770 "$XRAYTOOLS_DIR"

        for db in "$LIMITS_DB" "$USAGE_DB" "$SESSION_DB" "$USER_DB"; do
            if [ -f "$db" ]; then
                chown botxray:botxray "$db"
                chmod 0660 "$db"
            fi
        done
    else
        chmod 0750 "$XRAYTOOLS_DIR"
        for db in "$LIMITS_DB" "$USAGE_DB" "$SESSION_DB" "$USER_DB"; do
            if [ -f "$db" ]; then
                chown root:root "$db"
                chmod 0600 "$db"
            fi
        done
    fi
}

_apply_config_perms() {
    _detect_xray_owner
    local cfg_dir
    cfg_dir="$(dirname "$CONFIG_PATH")"

    local dir_mode="750"
    local file_mode="0640"
    if id -u botxray &>/dev/null; then
        dir_mode="2770"
        file_mode="0660"
    fi

    if [ -d "$cfg_dir" ]; then
        chown "root:${XRAY_GROUP}" "$cfg_dir"
        chmod "$dir_mode" "$cfg_dir"
    fi

    if [ -f "$CONFIG_PATH" ]; then
        chown "root:${XRAY_GROUP}" "$CONFIG_PATH"
        chmod "$file_mode" "$CONFIG_PATH"
    fi

    if [ -f "$PRESET_FILE" ]; then
        chown "root:${XRAY_GROUP}" "$PRESET_FILE"
        chmod "$file_mode" "$PRESET_FILE"
    fi

    _apply_xraytools_perms
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

# ================================================================
# GERENCIAMENTO SEGURO DE CONTA LINUX LOCAL
# ================================================================
_lock_linux_account() {
    local nick="$1"
    if getent passwd "$nick" >/dev/null 2>&1; then
        local uid shell
        uid=$(id -u "$nick" 2>/dev/null || echo 0)
        shell=$(getent passwd "$nick" | cut -d: -f7)
        if [ "$uid" -lt 1000 ] || [ "$shell" != "/bin/false" ]; then
            return 0
        fi
        usermod -L "$nick" 2>/dev/null || true
        chage -E 0 "$nick" 2>/dev/null || true
        passwd -l "$nick" 2>/dev/null || true
        pkill -KILL -u "$nick" 2>/dev/null || true
    fi
}

_unlock_linux_account() {
    local nick="$1"
    if [ -f /etc/shells ] && ! grep -qxF "/bin/false" /etc/shells 2>/dev/null; then
        echo "/bin/false" >> /etc/shells
    fi
    if getent passwd "$nick" >/dev/null 2>&1; then
        local uid shell
        uid=$(id -u "$nick" 2>/dev/null || echo 0)
        shell=$(getent passwd "$nick" | cut -d: -f7)
        if [ "$uid" -lt 1000 ] || [ "$shell" != "/bin/false" ]; then
            return 0
        fi
        usermod -U "$nick" 2>/dev/null || true
        chage -E -1 "$nick" 2>/dev/null || true
        passwd -u "$nick" 2>/dev/null || true
    fi
}

# ================================================================
# INICIALIZAÇÃO
# ================================================================
: > "$LOG_FILE"
mkdir -p "$XRAYTOOLS_DIR"
touch "$LIMITS_DB" "$USAGE_DB" "$SESSION_DB" "$USER_DB"
_apply_xraytools_perms
ensure_cmd jq jq

if [ "${1:-}" != "--cron" ]; then
    _detect_api_port && echo -e "${TXT_GREEN}✅ Porta API detectada: $XRAY_API_PORT${RESET}" \
    || echo -e "${TXT_YELLOW}⚠ Porta API não encontrada no config, usando fallback: $XRAY_API_PORT_DEFAULT${RESET}"
else
    _detect_api_port || true
fi

header_limit() {
    clear
    echo -e "${TITLE_BAR} CONTROLE DE CONSUMO (PERSISTENTE) — V1.5 ${RESET}"
    echo ""
    echo -e " ${TXT_CYAN}Porta API: ${XRAY_API_PORT}${RESET}"
    echo ""
}

func_get_api_port() {
    _detect_api_port
}

is_user_locked() {
    local nick="$1"
    jq -e --arg lock "LOCKED_${nick}" '
        any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?; .email == $lock)
    ' "$CONFIG_PATH" >/dev/null 2>&1
}

user_exists_in_config() {
    local nick="$1"
    jq -e --arg email "$nick" '
        any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?; .email == $email)
    ' "$CONFIG_PATH" >/dev/null 2>&1
}

get_real_uuid_from_db() {
    local nick="$1"
    awk -F'|' -v n="$nick" '$1==n {print $2; exit}' "$USER_DB" 2>/dev/null || true
}

func_bytes_to_human() {
    local b=${1:-0}
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    awk -v b="$b" 'BEGIN {
        if (b >= 1073741824) printf "%.2f GB\n", b / 1073741824
        else if (b >= 1048576) printf "%.2f MB\n", b / 1048576
        else printf "%.2f KB\n", b / 1024
    }'
}

# ================================================================
# DB HELPERS
# ================================================================
db_delete_key() {
    local file="$1" nick="$2"
    local tmp
    tmp=$(mktemp "${file}.tmp.XXXXXX")
    awk -F'|' -v n="$nick" '$1!=n {print}' "$file" > "$tmp"
    mv -f "$tmp" "$file"
    _apply_xraytools_perms
}

db_get_value() {
    local file="$1" nick="$2"
    awk -F'|' -v n="$nick" '$1==n {print $2; exit}' "$file" 2>/dev/null || true
}

db_set_value() {
    local file="$1" nick="$2" value="$3"
    db_delete_key "$file" "$nick"
    echo "$nick|$value" >> "$file"
    _apply_xraytools_perms
}

# ================================================================
# ESCRITA SEGURA NO CONFIG
# ================================================================
safe_config_write() {
    local jq_filter="$1"
    shift
    local tmp
    tmp=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
    if ! jq "$@" "$jq_filter" "$CONFIG_PATH" > "$tmp" 2>>"$LOG_FILE"; then
        rm -f "$tmp"
        echo -e "${TXT_RED}❌ Erro ao processar config com jq.${RESET}" >&2
        return 1
    fi
    if ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo -e "${TXT_RED}❌ Config gerado é JSON inválido. Abortando.${RESET}" >&2
        return 1
    fi
    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    mv -f "$tmp" "$CONFIG_PATH"
    _apply_config_perms
}

# ================================================================
# FUNÇÕES DA API XRAY (HOT-RELOAD)
# ================================================================
_api_remove() {
    local email="$1"
    [ ! -x "$XRAY_BIN" ] && return 1
    systemctl is-active --quiet xray 2>/dev/null || return 1
    [ -z "${XRAY_API_PORT:-}" ] && func_get_api_port || true
    timeout "$XRAY_API_TIMEOUT" "$XRAY_BIN" api removeuser \
        -server="127.0.0.1:${XRAY_API_PORT}" \
        -inboundTag="inbound-turbonet" \
        -email="$email" >>"$LOG_FILE" 2>&1
}

_api_add_client() {
    local email="$1" cred="$2"
    [ ! -x "$XRAY_BIN" ] && return 1
    systemctl is-active --quiet xray 2>/dev/null || return 1
    [ -z "${XRAY_API_PORT:-}" ] && func_get_api_port || true

    local proto has_vision preset_net tmp_api_json
    proto=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") | .protocol // "vless"' "$CONFIG_PATH" 2>/dev/null | head -1)
    preset_net=$(jq -r '.network // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    has_vision=$(jq -r '
        [.inbounds[]? | select(.tag=="inbound-turbonet") | .settings.clients[]? | select(.flow=="xtls-rprx-vision")] | length
    ' "$CONFIG_PATH" 2>/dev/null || echo 0)

    tmp_api_json=$(mktemp /tmp/xray_limiter_api_XXXXXX.json)
    _TMP_FILES+=("$tmp_api_json")

    if [ "$proto" = "trojan" ]; then
        jq -n --arg pwd "$cred" --arg em "$email" \
            '{inbounds:[{tag:"inbound-turbonet",settings:{clients:[{password:$pwd,email:$em,level:0}]}}]}' > "$tmp_api_json"
    elif [ "$preset_net" = "vision" ] || [ "${has_vision:-0}" -gt 0 ]; then
        jq -n --arg id "$cred" --arg em "$email" \
            '{inbounds:[{tag:"inbound-turbonet",settings:{clients:[{id:$id,email:$em,level:0,flow:"xtls-rprx-vision"}]}}]}' > "$tmp_api_json"
    else
        jq -n --arg id "$cred" --arg em "$email" \
            '{inbounds:[{tag:"inbound-turbonet",settings:{clients:[{id:$id,email:$em,level:0}]}}]}' > "$tmp_api_json"
    fi

    if timeout "$XRAY_API_TIMEOUT" "$XRAY_BIN" api adduser \
        -s "127.0.0.1:${XRAY_API_PORT}" "$tmp_api_json" >>"$LOG_FILE" 2>&1; then
        rm -f "$tmp_api_json"
        return 0
    fi

    rm -f "$tmp_api_json"
    return 1
}

_hot_reload_swap_client() {
    local old_email="$1" new_email="$2" new_cred="$3"
    if ! _test_xray_config "$CONFIG_PATH" >>"$LOG_FILE" 2>&1; then
        return 1
    fi
    _api_remove "$old_email" 2>/dev/null || return 1
    _api_add_client "$new_email" "$new_cred" || return 1
    return 0
}

apply_config_change_and_reload() {
    if ! _test_xray_config "$CONFIG_PATH" >>"$LOG_FILE" 2>&1; then
        echo -e "${TXT_RED}❌ Validação do config.json falhou. Revertendo...${RESET}" >&2
        if [ -f "${CONFIG_PATH}.bak" ]; then
            mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
            _apply_config_perms
        fi
        return 1
    fi

    if ! systemctl restart xray >>"$LOG_FILE" 2>&1 || ! _wait_xray_active; then
        echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}" >&2
        if [ -f "${CONFIG_PATH}.bak" ]; then
            mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
            _apply_config_perms
            systemctl restart xray >/dev/null 2>&1 || true
        fi
        return 1
    fi
    return 0
}

# ================================================================
# CHAMADA À API COM TIMEOUT E PARSING SEGURO
# ================================================================
xray_api_stat() {
    local name="$1"
    [ -z "${XRAY_API_PORT:-}" ] && func_get_api_port || true
    local raw val
    raw=$(timeout "$XRAY_API_TIMEOUT" \
        "$XRAY_BIN" api stats \
        -server="127.0.0.1:$XRAY_API_PORT" \
        -name "$name" 2>/dev/null || echo "{}")

    val=$(echo "$raw" | jq -r '.stat.value // 0' 2>/dev/null | tr -cd '0-9')
    [[ "${val:-}" =~ ^[0-9]+$ ]] || val=0
    echo "$val"
}

# ================================================================
# FUNÇÕES DE MENU
# ================================================================
func_set_limit() {
    header_limit
    echo "Definir Limite de Dados"
    echo "--------------------------------------"
    read -rp "Nick do usuário: " nick_raw
    [ -n "${nick_raw:-}" ] || return

    if ! validate_nick "$nick_raw"; then
        echo -e "${TXT_RED}❌ Nick inválido. Use 5-9 letras/números.${RESET}"
        read -rp "Enter..."; return
    fi

    local nick
    nick=$(echo "$nick_raw" | tr '[:upper:]' '[:lower:]')

    if [ ! -s "$CONFIG_PATH" ] || ! jq empty "$CONFIG_PATH" 2>/dev/null; then
        echo -e "${TXT_RED}❌ Config inválida ou não encontrada.${RESET}"
        read -rp "Enter..."; return
    fi

    func_get_api_port || true

    local is_locked=false
    if is_user_locked "$nick"; then
        is_locked=true
    elif ! user_exists_in_config "$nick"; then
        echo -e "${TXT_RED}❌ Usuário não encontrado no Xray!${RESET}"
        read -rp "Enter..."; return
    fi

    read -rp "Limite em GB: " gb_limit
    if ! [[ "${gb_limit:-}" =~ ^[0-9]+$ ]] || [ "$gb_limit" -lt 1 ] || [ "$gb_limit" -gt 1048576 ]; then
        echo -e "${TXT_RED}❌ Limite inválido (use entre 1 e 1048576 GB).${RESET}"; sleep 1; return
    fi

    local bytes_limit=$(( gb_limit * 1073741824 ))
    db_set_value "$LIMITS_DB" "$nick" "$bytes_limit"

    read -rp "Zerar consumo atual? [s/N]: " zerar
    if [[ "${zerar:-n}" =~ ^[Ss]$ ]]; then
        db_delete_key "$USAGE_DB" "$nick"
        db_delete_key "$SESSION_DB" "$nick"
        echo -e "${TXT_CYAN}Histórico zerado.${RESET}"
    fi

    if [ "$is_locked" = true ]; then
        local real_cred
        real_cred="$(get_real_uuid_from_db "$nick")"
        if [ -n "${real_cred:-}" ]; then
            acquire_lock
            if safe_config_write \
                '(.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
                (if type=="array" then . else [] end)
                |
                (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
                map(if .email == $locked then
                    .email = $nick
                    | (if has("password") then .password = $cred else . end)
                    | (if has("id") then .id = $cred else . end)
                else . end)' \
                --arg nick "$nick" --arg locked "LOCKED_$nick" --arg cred "$real_cred"; then

                if _hot_reload_swap_client "LOCKED_${nick}" "$nick" "$real_cred"; then
                    echo -e "${TXT_GREEN}⚡ Usuário desbloqueado via API sem derrubar conexões ativas!${RESET}"
                elif apply_config_change_and_reload; then
                    echo -e "${TXT_GREEN}✅ Usuário desbloqueado!${RESET}"
                fi
            fi

            _unlock_linux_account "$nick"
            release_lock
        else
            echo -e "${TXT_YELLOW}⚠ Credencial real não encontrada. Desbloqueio manual necessário.${RESET}"
        fi
    fi

    echo -e "${TXT_GREEN}✅ Limite salvo: ${gb_limit} GB${RESET}"
    read -rp "Enter para voltar..."
}

func_view_usage() {
    func_get_api_port || true
    header_limit
    printf "%-14s | %-12s | %-12s | %s\n" "USUÁRIO" "USADO" "LIMITE" "STATUS"
    echo "-----------------------------------------------------------"

    local all_nicks=()
    while IFS='|' read -r name _; do
        [ -n "${name:-}" ] && all_nicks+=("$name")
    done < "$USER_DB"
    while IFS='|' read -r name _; do
        [ -n "${name:-}" ] || continue
        local found=0
        for n in "${all_nicks[@]:-}"; do [ "$n" = "$name" ] && found=1 && break; done
        [ "$found" -eq 0 ] && all_nicks+=("$name")
    done < "$LIMITS_DB"

    for nick in "${all_nicks[@]:-}"; do
        [ -n "$nick" ] || continue
        local usage_total limit_bytes
        usage_total="$(db_get_value "$USAGE_DB" "$nick")"
        [[ "${usage_total:-}" =~ ^[0-9]+$ ]] || usage_total=0
        limit_bytes="$(db_get_value "$LIMITS_DB" "$nick")"

        local limit_h status
        if [ -z "${limit_bytes:-}" ] || ! [[ "$limit_bytes" =~ ^[0-9]+$ ]] || [ "$limit_bytes" -le 0 ]; then
            limit_h="Sem limite"
            status="${TXT_GREEN}Livre${RESET}"
        else
            limit_h="$(func_bytes_to_human "$limit_bytes")"
            if is_user_locked "$nick" 2>/dev/null; then
                status="${TXT_RED}BLOQUEADO${RESET}"
            elif [ "$usage_total" -ge "$limit_bytes" ]; then
                status="${TXT_RED}EXCEDIDO${RESET}"
            else
                local pct=$(( usage_total * 100 / limit_bytes ))
                status="${TXT_CYAN}${pct}%${RESET}"
            fi
        fi
        local used_h
        used_h="$(func_bytes_to_human "$usage_total")"
        printf "%-14s | %-12s | %-12s | %b\n" "$nick" "$used_h" "$limit_h" "$status"
    done

    echo "-----------------------------------------------------------"
    echo ""
    read -rp "Enter para voltar..."
}

func_remove_limit() {
    header_limit
    read -rp "Usuário para remover limite: " nick_raw
    [ -n "${nick_raw:-}" ] || return

    if ! validate_nick "$nick_raw"; then
        echo -e "${TXT_RED}❌ Nick inválido.${RESET}"; sleep 1; return
    fi

    local nick
    nick=$(echo "$nick_raw" | tr '[:upper:]' '[:lower:]')

    db_delete_key "$LIMITS_DB" "$nick"
    db_delete_key "$USAGE_DB" "$nick"
    db_delete_key "$SESSION_DB" "$nick"

    if [ -s "$CONFIG_PATH" ] && jq empty "$CONFIG_PATH" 2>/dev/null && is_user_locked "$nick" 2>/dev/null; then
        local real_cred
        real_cred="$(get_real_uuid_from_db "$nick")"
        if [ -n "${real_cred:-}" ]; then
            acquire_lock
            if safe_config_write \
                '(.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
                (if type=="array" then . else [] end)
                |
                (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
                map(if .email == $locked then
                    .email = $nick
                    | (if has("password") then .password = $cred else . end)
                    | (if has("id") then .id = $cred else . end)
                else . end)' \
                --arg nick "$nick" --arg locked "LOCKED_$nick" --arg cred "$real_cred"; then

                if _hot_reload_swap_client "LOCKED_${nick}" "$nick" "$real_cred"; then
                    echo -e "${TXT_GREEN}⚡ Limite removido e usuário desbloqueado via API!${RESET}"
                elif apply_config_change_and_reload; then
                    echo -e "${TXT_GREEN}✅ Limite removido e usuário desbloqueado!${RESET}"
                fi
            fi

            _unlock_linux_account "$nick"
            release_lock
        fi
    fi

    echo -e "${TXT_GREEN}✅ Limite removido e histórico limpo.${RESET}"
    sleep 2
}

func_check_and_block() {
    local MODE="$1"

    func_get_api_port || true

    [ "$MODE" != "--cron" ] && {
        header_limit
        [ "$MODE" = "--sync-only" ] && echo "Sincronizando (sem bloqueio)..." || echo "Sincronizando e aplicando regras..."
    }

    if [ ! -s "$CONFIG_PATH" ] || ! jq empty "$CONFIG_PATH" 2>/dev/null; then
        [ "$MODE" != "--cron" ] && echo -e "${TXT_RED}❌ Config inválida.${RESET}"
        return 1
    fi

    if ! jq -e '.inbounds[]? | select(.tag=="api" or .protocol=="dokodemo-door")' "$CONFIG_PATH" >/dev/null 2>&1; then
        [ "$MODE" != "--cron" ] && {
            echo -e "${TXT_RED}❌ Inbound API não configurado.${RESET}"
            read -rp "Enter..."
        }
        return 1
    fi

    acquire_lock "$MODE"
    local blocked_count=0
    local need_full_restart=false

    local tmp_usage tmp_session
    tmp_usage=$(mktemp "${USAGE_DB}.work.XXXXXX")
    tmp_session=$(mktemp "${SESSION_DB}.work.XXXXXX")
    _TMP_FILES+=("$tmp_usage" "$tmp_session")

    cp "$USAGE_DB" "$tmp_usage"
    cp "$SESSION_DB" "$tmp_session"

    while IFS='|' read -r nick limit_bytes; do
        [ -n "${nick:-}" ] || continue
        [[ "${limit_bytes:-}" =~ ^[0-9]+$ ]] || continue
        [ "$limit_bytes" -le 0 ] && continue
        is_user_locked "$nick" 2>/dev/null && continue

        local down up
        down=$(xray_api_stat "user>>>${nick}>>>traffic>>>downlink")
        up=$(xray_api_stat "user>>>${nick}>>>traffic>>>uplink")
        [[ "${down:-}" =~ ^[0-9]+$ ]] || down=0
        [[ "${up:-}" =~ ^[0-9]+$ ]] || up=0

        local current_session=$(( down + up ))
        local last_session historical_usage
        last_session="$(db_get_value "$tmp_session" "$nick")"
        [[ "${last_session:-}" =~ ^[0-9]+$ ]] || last_session=0
        historical_usage="$(db_get_value "$tmp_usage" "$nick")"
        [[ "${historical_usage:-}" =~ ^[0-9]+$ ]] || historical_usage=0

        local delta
        if [ "$current_session" -lt "$last_session" ]; then
            delta="$current_session"
        else
            delta=$(( current_session - last_session ))
        fi

        local new_historical=$(( historical_usage + delta ))
        db_set_value "$tmp_usage" "$nick" "$new_historical"
        db_set_value "$tmp_session" "$nick" "$current_session"

        if [ "$new_historical" -ge "$limit_bytes" ]; then
            if [ "$MODE" = "--sync-only" ]; then
                [ "$MODE" != "--cron" ] && \
                echo -e "${TXT_YELLOW}⚠ $nick excedeu limite (bloqueio pendente).${RESET}"
            else
                [ "$MODE" != "--cron" ] && \
                echo -e "${TXT_RED}❌ $nick estourou. Bloqueando...${RESET}"

                local fake_uuid fake_pass
                fake_uuid=$(generate_uuid) || {
                    echo -e "${TXT_RED}❌ UUID falhou para $nick.${RESET}" >&2
                    continue
                }
                fake_pass=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32)

                local tmp_block
                tmp_block=$(mktemp "${CONFIG_PATH}.block.XXXXXX")
                if jq \
                    --arg nick "$nick" \
                    --arg locked "LOCKED_$nick" \
                    --arg fake "$fake_uuid" \
                    --arg fakepass "$fake_pass" \
                    '(.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
                    (if type=="array" then . else [] end)
                    |
                    (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
                    map(if .email == $nick then
                        .email = $locked
                        | (if has("password") then .password = $fakepass else . end)
                        | (if has("id") then .id = $fake else . end)
                    else . end)' \
                    "$CONFIG_PATH" > "$tmp_block" 2>>"$LOG_FILE" \
                    && jq empty "$tmp_block" 2>/dev/null; then
                    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
                    mv -f "$tmp_block" "$CONFIG_PATH"
                    _apply_config_perms

                    local proto fake_cred
                    proto=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") | .protocol // "vless"' "$CONFIG_PATH" 2>/dev/null | head -1)
                    fake_cred="$fake_uuid"
                    [ "$proto" = "trojan" ] && fake_cred="$fake_pass"

                    if ! _hot_reload_swap_client "$nick" "LOCKED_${nick}" "$fake_cred"; then
                        need_full_restart=true
                    fi

                    # Guilhotina SSH/SOCKS5: trava conta e derruba conexões ativas
                    _lock_linux_account "$nick"

                    blocked_count=$(( blocked_count + 1 ))
                else
                    rm -f "$tmp_block"
                    [ "$MODE" != "--cron" ] && \
                    echo -e "${TXT_RED}⚠ Falha ao bloquear $nick — config não alterado.${RESET}"
                fi
            fi
        fi
    done < "$LIMITS_DB"

    # Promove cópias de trabalho para DBs reais e preserva dono/permissões do botxray
    mv -f "$tmp_usage" "$USAGE_DB"
    mv -f "$tmp_session" "$SESSION_DB"
    _apply_xraytools_perms

    if [ "$need_full_restart" = true ]; then
        apply_config_change_and_reload || true
        [ "$MODE" != "--cron" ] && \
        echo -e "${TXT_RED}🚫 ${blocked_count} usuário(s) bloqueado(s) (via restart).${RESET}"
    elif [ "$blocked_count" -gt 0 ]; then
        [ "$MODE" != "--cron" ] && \
        echo -e "${TXT_RED}🚫 ${blocked_count} usuário(s) bloqueado(s) via API sem derrubar clientes ativos.${RESET}"
    else
        [ "$MODE" != "--cron" ] && \
        echo -e "${TXT_GREEN}✅ Dados atualizados. Nenhum bloqueio necessário.${RESET}"
    fi

    release_lock
    [ "$MODE" != "--cron" ] && read -rp "Enter..."
}

# ================================================================
# ENTRY POINT
# ================================================================
if [ "${1:-}" = "--cron" ]; then
    func_get_api_port || true
    func_check_and_block "--cron"
    exit 0
fi

while true; do
    header_limit
    echo -e "${TXT_CYAN}[1] DEFINIR/ALTERAR LIMITE${RESET}"
    echo -e "${TXT_CYAN}[2] VER CONSUMO ACUMULADO${RESET}"
    echo -e "${TXT_CYAN}[3] REMOVER LIMITE${RESET}"
    echo -e "${TXT_RED}[4] VERIFICAR E BLOQUEAR EXCEDENTES${RESET}"
    echo -e "${TXT_YELLOW}[5] APENAS SINCRONIZAR (SEM BLOQUEIO)${RESET}"
    echo -e "${TXT_CYAN}[0] VOLTAR${RESET}"
    echo "--------------------------------------"
    read -rp "Opção: " choice

    case "${choice:-}" in
        1) func_set_limit ;;
        2) func_view_usage ;;
        3) func_remove_limit ;;
        4) func_check_and_block "--enforce" ;;
        5) func_check_and_block "--sync-only" ;;
        0) exit 0 ;;
        *) echo "Inválido"; sleep 1 ;;
    esac
done
