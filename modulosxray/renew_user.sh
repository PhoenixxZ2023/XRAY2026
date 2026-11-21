#!/bin/bash
# renew_user.sh - TURBONET XRAY V1.4 (PRO + Hot-Reload API + Compatibilidade Bot Telegram)
# Atualizações V1.4:
#   - _apply_config_perms e _apply_xraytools_perms preservam permissões 2770/0660 quando o usuário `botxray` existe
#   - Hot-reload via API interna (`xray api removeuser -email=...` + `xray api adduser`) ao reativar suspensos sem derrubar clientes ativos
#   - Desbloqueio completo da conta Linux (`usermod -U`, `chage -E -1`, `passwd -u`) com proteção para contas do sistema (UID < 1000)
#   - Validação estrita do nick (`^[a-zA-Z0-9]{5,9}$`) e sincronização via flock com limiterxray.sh

set -Eeuo pipefail

# --- CLEANUP CENTRALIZADO ---
_TMP_FILES=()
_cleanup() {
    for f in "${_TMP_FILES[@]:-}"; do
        [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
    done
    flock -u 9 2>/dev/null || true
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

XRAYTOOLS_DIR="/opt/XrayTools"
USER_DB="${XRAYTOOLS_DIR}/users.db"
USAGE_DB="${XRAYTOOLS_DIR}/usage.db"
SESSION_DB="${XRAYTOOLS_DIR}/session.db"
LIMITS_DB="${XRAYTOOLS_DIR}/limits.db"
CONN_INFO_DIR="${XRAYTOOLS_DIR}/users"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
XRAY_BIN="/usr/local/bin/xray"
LOCK_FILE="/tmp/limiterxray.lock"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- DEPENDÊNCIAS E VERIFICAÇÕES ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"; exit 1
fi

if [ ! -s "$USER_DB" ]; then
    echo -e "${TXT_RED}❌ Banco de dados vazio ou inexistente.${RESET}"
    sleep 2; exit 1
fi

command -v jq >/dev/null 2>&1 || { echo -e "${TXT_RED}❌ 'jq' não instalado.${RESET}"; exit 1; }
command -v awk >/dev/null 2>&1 || { echo -e "${TXT_RED}❌ 'awk' não instalado.${RESET}"; exit 1; }

# Carrega sanitização se disponível
[ -f "/usr/local/bin/sanitize.sh" ] && source /usr/local/bin/sanitize.sh

validate_nick() { [[ "${1:-}" =~ ^[a-zA-Z0-9]{5,9}$ ]]; }

# --- DETECÇÃO DINÂMICA DE DONO E PERMISSÕES ---
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
    mkdir -p "$XRAYTOOLS_DIR" "$CONN_INFO_DIR"
    if id -u botxray &>/dev/null; then
        chown root:botxray "$XRAYTOOLS_DIR"
        chmod 2770 "$XRAYTOOLS_DIR"

        chown root:botxray "$CONN_INFO_DIR"
        chmod 0750 "$CONN_INFO_DIR"

        for db in "$USER_DB" "$USAGE_DB" "$SESSION_DB" "$LIMITS_DB"; do
            if [ -f "$db" ]; then
                chown botxray:botxray "$db"
                chmod 0660 "$db"
            fi
        done
    else
        chmod 0750 "$XRAYTOOLS_DIR"
        chmod 0700 "$CONN_INFO_DIR"
        for db in "$USER_DB" "$USAGE_DB" "$SESSION_DB" "$LIMITS_DB"; do
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

# --- HELPERS DA API XRAY (HOT-RELOAD) ---
_xray_api_port() {
    jq -r '.inbounds[]? | select(.tag=="api" or .protocol=="dokodemo-door") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1
}

_hot_reload_unblock_user() {
    local nick="$1" locked_nick="$2" real_cred="$3"
    [ ! -x "$XRAY_BIN" ] && return 1
    systemctl is-active --quiet xray 2>/dev/null || return 1

    local api_port
    api_port=$(_xray_api_port)
    [ -z "${api_port:-}" ] && return 1

    "$XRAY_BIN" api removeuser \
        -server="127.0.0.1:${api_port}" \
        -inboundTag="inbound-turbonet" \
        -email="$locked_nick" >/dev/null 2>&1 || true

    local proto has_vision preset_net tmp_api_json
    proto=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") | .protocol // "vless"' "$CONFIG_PATH" 2>/dev/null | head -1)
    preset_net=$(jq -r '.network // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    has_vision=$(jq -r '
        [.inbounds[]? | select(.tag=="inbound-turbonet") | .settings.clients[]? | select(.flow=="xtls-rprx-vision")] | length
    ' "$CONFIG_PATH" 2>/dev/null || echo 0)

    tmp_api_json=$(mktemp /tmp/xray_renew_api_XXXXXX.json)
    _TMP_FILES+=("$tmp_api_json")

    if [ "$proto" = "trojan" ]; then
        jq -n --arg pwd "$real_cred" --arg em "$nick" \
            '{inbounds:[{tag:"inbound-turbonet",settings:{clients:[{password:$pwd,email:$em,level:0}]}}]}' > "$tmp_api_json"
    elif [ "$preset_net" = "vision" ] || [ "${has_vision:-0}" -gt 0 ]; then
        jq -n --arg id "$real_cred" --arg em "$nick" \
            '{inbounds:[{tag:"inbound-turbonet",settings:{clients:[{id:$id,email:$em,level:0,flow:"xtls-rprx-vision"}]}}]}' > "$tmp_api_json"
    else
        jq -n --arg id "$real_cred" --arg em "$nick" \
            '{inbounds:[{tag:"inbound-turbonet",settings:{clients:[{id:$id,email:$em,level:0}]}}]}' > "$tmp_api_json"
    fi

    if "$XRAY_BIN" api adduser -s "127.0.0.1:${api_port}" "$tmp_api_json" >/dev/null 2>&1; then
        rm -f "$tmp_api_json"
        return 0
    fi

    rm -f "$tmp_api_json"
    return 1
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
            echo -e "  ↳ ${TXT_YELLOW}Conta Linux '${nick}' pertence ao sistema — não alterada.${RESET}"
            return 1
        fi
        usermod -U "$nick" 2>/dev/null || true
        chage -E -1 "$nick" 2>/dev/null || true
        passwd -u "$nick" 2>/dev/null || true
        return 0
    fi
    return 1
}

_apply_xraytools_perms

# --- INTERFACE ---
clear
echo -e "${TITLE_BAR}   RENOVAR USUÁRIO (V1.4 PRO)   ${RESET}"
echo ""

read -rp "Nick do usuário (0 para voltar): " nick_raw
[ "${nick_raw:-0}" = "0" ] || [ -z "${nick_raw:-}" ] && exit 0

if ! validate_nick "$nick_raw"; then
    echo -e "${TXT_RED}❌ Nick inválido. Use de 5 a 9 letras/números.${RESET}"
    sleep 2; exit 1
fi

nick=$(echo "$nick_raw" | tr '[:upper:]' '[:lower:]')

db_line=$(awk -F'|' -v n="$nick" '$1==n {print $0; exit}' "$USER_DB" 2>/dev/null || true)
if [ -z "$db_line" ]; then
    echo -e "${TXT_RED}❌ Usuário '${nick}' não encontrado no sistema.${RESET}"
    sleep 2; exit 1
fi

IFS='|' read -r db_nick db_uuid data_atual db_pass db_limit _rest <<< "$db_line"

# Verifica se está suspenso/bloqueado no config.json
is_locked=false
if [ -s "$CONFIG_PATH" ] && jq -e --arg lock "LOCKED_${nick}" '
    any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?; .email == $lock)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    is_locked=true
fi

# Cálculo Inteligente de Data
hoje_ts=$(date -d "$(date +%F)" +%s)
exp_ts=$(date -d "${data_atual:-1970-01-01}" +%s 2>/dev/null || echo 0)

status_txt="${TXT_GREEN}ATIVO${RESET}"
data_base="$data_atual"

if [ "$is_locked" = true ]; then
    status_txt="${TXT_RED}BLOQUEADO / SUSPENSO${RESET}"
    [ "$exp_ts" -lt "$hoje_ts" ] && data_base=$(date +%F)
elif [ "$exp_ts" -lt "$hoje_ts" ]; then
    status_txt="${TXT_YELLOW}VENCIDO${RESET}"
    data_base=$(date +%F)
fi

echo -e "-----------------------------------------"
echo -e " 👤 Usuário: ${TXT_CYAN}${nick}${RESET}"
echo -e " 📅 Vencimento Atual: ${TXT_YELLOW}${data_atual}${RESET}"
echo -e " 🚥 Status: ${status_txt}"
echo -e "-----------------------------------------"
echo ""

read -rp "Quantos dias deseja adicionar? [Enter = 30]: " dias
dias="${dias:-30}"
[[ "$dias" =~ ^[0-9]+$ ]] || dias=30
(( dias < 1 || dias > 3650 )) && dias=30

nova_data=$(date -d "${data_base} +${dias} days" +%F 2>/dev/null || date -d "+${dias} days" +%F)

echo -e "Nova data de vencimento: ${TXT_GREEN}${nova_data}${RESET}"
echo ""

# Reset de Consumo de Dados (Integração Limiter)
reset_usage="n"
if [ -f "$USAGE_DB" ] && awk -F'|' -v n="$nick" '$1==n{found=1} END{exit found?0:1}' "$USAGE_DB" 2>/dev/null; then
    uso_bytes=$(awk -F'|' -v n="$nick" '$1==n {print $2; exit}' "$USAGE_DB" 2>/dev/null || echo 0)
    [[ "${uso_bytes:-0}" =~ ^[0-9]+$ ]] || uso_bytes=0
    uso_mb=$(( uso_bytes / 1048576 ))
    echo -e "Este usuário consumiu ${TXT_CYAN}${uso_mb} MB${RESET} na franquia atual."
    read -rp "Deseja ZERAR o consumo de dados (GB) dele? [S/n]: " reset_usage
    reset_usage=${reset_usage:-s}
fi

echo ""
read -rp "Confirmar renovação? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

echo ""
echo "Aplicando renovação..."

exec 9>"$LOCK_FILE"
flock -w 10 9 || true

# 1. Atualiza Banco de Dados de Forma Atômica
tmp_db=$(mktemp "${USER_DB}.tmp.XXXXXX")
_TMP_FILES+=("$tmp_db")
awk -F'|' -v n="$nick" -v nd="$nova_data" 'BEGIN {OFS="|"} $1==n {$3=nd} {print $0}' "$USER_DB" > "$tmp_db"
mv -f "$tmp_db" "$USER_DB"
_apply_xraytools_perms

# 2. Desbloqueio Xray - Caso estivesse suspenso
if [ "$is_locked" = true ]; then
    echo "Identificado usuário suspenso. Restaurando acesso Xray..."

    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
    _TMP_FILES+=("$tmp_cfg")

    jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg cred "$db_uuid" '
        (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
            (if type == "array" then . else [] end)
        |
        (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
            map(if .email == $locked then
                .email = $nick
                | (if has("password") then .password = $cred else . end)
                | (if has("id") then .id = $cred else . end)
            else . end)
    ' "$CONFIG_PATH" > "$tmp_cfg"

    if jq empty "$tmp_cfg" 2>/dev/null; then
        mv -f "$tmp_cfg" "$CONFIG_PATH"
        _apply_config_perms

        if _test_xray_config "$CONFIG_PATH" >/dev/null 2>&1; then
            if _hot_reload_unblock_user "$nick" "LOCKED_${nick}" "$db_uuid"; then
                echo -e "  ↳ ${TXT_GREEN}⚡ Acesso Xray restaurado via API sem derrubar conexões ativas.${RESET}"
            elif systemctl restart xray >/dev/null 2>&1 && _wait_xray_active; then
                echo -e "  ↳ ${TXT_GREEN}Acesso Xray restaurado com sucesso.${RESET}"
            else
                echo -e "  ↳ ${TXT_RED}Falha ao reiniciar Xray. Revertendo config...${RESET}"
                mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
                _apply_config_perms
                systemctl restart xray >/dev/null 2>&1 || true
            fi
        else
            echo -e "  ↳ ${TXT_RED}Validação do config falhou. Revertendo...${RESET}"
            mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
            _apply_config_perms
        fi
    else
        echo -e "  ↳ ${TXT_RED}Erro ao restaurar JSON. Acesso Xray não desbloqueado.${RESET}"
    fi
fi

# 3. Zera Consumo do Limiter (Opcional)
if [[ "${reset_usage}" =~ ^[Ss]$ ]]; then
    if [ -f "$USAGE_DB" ]; then
        tmp_usage=$(mktemp "${USAGE_DB}.tmp.XXXXXX")
        _TMP_FILES+=("$tmp_usage")
        awk -F'|' -v n="$nick" '$1!=n {print}' "$USAGE_DB" > "$tmp_usage"
        mv -f "$tmp_usage" "$USAGE_DB"
    fi
    if [ -f "$SESSION_DB" ]; then
        tmp_session=$(mktemp "${SESSION_DB}.tmp.XXXXXX")
        _TMP_FILES+=("$tmp_session")
        awk -F'|' -v n="$nick" '$1!=n {print}' "$SESSION_DB" > "$tmp_session"
        mv -f "$tmp_session" "$SESSION_DB"
    fi
    _apply_xraytools_perms
    echo -e "  ↳ ${TXT_GREEN}Consumo de dados zerado.${RESET}"
fi

# 4. Desbloqueio SSH/Dropbear/SOCKS5 Local
if _unlock_linux_account "$nick"; then
    echo -e "  ↳ ${TXT_GREEN}Acesso SSH/SOCKS5 local habilitado.${RESET}"
fi

# 5. Atualiza Arquivo de Conexão Individual
user_file="${CONN_INFO_DIR}/${nick}.txt"
if [ -f "$user_file" ]; then
    sed -i "s/^EXPIRA=.*/EXPIRA=${nova_data}/" "$user_file"
    if id -u botxray &>/dev/null; then
        chown root:botxray "$user_file"
        chmod 0640 "$user_file"
    fi
fi

flock -u 9 2>/dev/null || true

echo ""
echo -e "${TXT_GREEN}✅ Usuário '${nick}' renovado com sucesso!${RESET}"
echo -e "Nova Expiração: ${TXT_CYAN}${nova_data}${RESET} (+${dias} dias)"
echo "-----------------------------------------"
read -rp "Pressione Enter para voltar ao menu..."
