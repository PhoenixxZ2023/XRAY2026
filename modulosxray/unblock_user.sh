#!/bin/bash
# unblock_user.sh - TURBONET XRAY V1.2 (PRO + Compatibilidade Bot Telegram)
# Atualizações V1.2:
#   - _apply_config_perms e _apply_xraytools_perms preservam permissões 2770/0660 quando o usuário `botxray` existe
#   - Hot-reload via API interna (`xray api removeuser -email=...` + `xray api adduser`) sem derrubar clientes ativos
#   - Desbloqueio completo da conta Linux (`usermod -U`, `chage -E -1`, `passwd -u`) com proteção para contas do sistema (UID < 1000)
#   - Verificação de root (EUID) no início e suporte completo a VLESS, Vision e Trojan

set -Eeuo pipefail

XRAYTOOLS_DIR="/opt/XrayTools"
USER_DB="${XRAYTOOLS_DIR}/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
LOG_FILE="/tmp/unblock_user.log"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
fi

# --- CLEANUP CENTRALIZADO ---
_tmp_cfg=""
_tmp_api_json=""
_cleanup() {
    [ -n "${_tmp_cfg:-}" ] && rm -f "$_tmp_cfg"
    [ -n "${_tmp_api_json:-}" ] && rm -f "$_tmp_api_json"
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

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
    mkdir -p "$XRAYTOOLS_DIR"
    if id -u botxray &>/dev/null; then
        chown root:botxray "$XRAYTOOLS_DIR"
        chmod 2770 "$XRAYTOOLS_DIR"

        if [ -f "$USER_DB" ]; then
            chown botxray:botxray "$USER_DB"
            chmod 0660 "$USER_DB"
        fi
    else
        chmod 0750 "$XRAYTOOLS_DIR"
        if [ -f "$USER_DB" ]; then
            chown root:root "$USER_DB"
            chmod 0600 "$USER_DB"
        fi
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
    [ ! -x /usr/local/bin/xray ] && return 0
    _detect_xray_owner
    if command -v runuser &>/dev/null && [ "$XRAY_USER" != "root" ]; then
        runuser -u "$XRAY_USER" -- /usr/local/bin/xray run -test -config "$cfg"
    else
        /usr/local/bin/xray run -test -config "$cfg"
    fi
}

# --- DETECÇÃO DE DISTRO ---
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

validate_nick() { [[ "${1:-}" =~ ^[a-zA-Z0-9]{5,9}$ ]]; }

validate_credential() {
    local c="${1:-}"
    [[ "$c" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && return 0
    [[ "$c" =~ ^[0-9a-fA-F]{32}$ ]] && return 0
    return 1
}

# --- VERIFICAÇÃO DE XRAY ATIVO COM RETRY ---
_wait_xray_active() {
    local tries=5
    while [ "$tries" -gt 0 ]; do
        systemctl is-active --quiet xray 2>/dev/null && return 0
        sleep 1
        tries=$((tries - 1))
    done
    return 1
}

# --- HOT-RELOAD VIA API INTERNA DO XRAY ---
_xray_api_port() {
    jq -r '.inbounds[]? | select(.tag=="api" or .protocol=="dokodemo-door") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1
}

_hot_reload_unblock_user() {
    local nick="$1" locked_nick="$2" real_cred="$3"
    [ ! -x /usr/local/bin/xray ] && return 1
    systemctl is-active --quiet xray 2>/dev/null || return 1

    local api_port
    api_port=$(_xray_api_port)
    [ -z "${api_port:-}" ] && return 1

    /usr/local/bin/xray api removeuser \
        -server="127.0.0.1:${api_port}" \
        -inboundTag="inbound-turbonet" \
        -email="$locked_nick" >>"$LOG_FILE" 2>&1 || true

    local proto has_vision preset_net
    proto=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") | .protocol // "vless"' "$CONFIG_PATH" 2>/dev/null | head -1)
    preset_net=$(jq -r '.network // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    has_vision=$(jq -r '
        [.inbounds[]? | select(.tag=="inbound-turbonet") | .settings.clients[]? | select(.flow=="xtls-rprx-vision")] | length
    ' "$CONFIG_PATH" 2>/dev/null || echo 0)

    _tmp_api_json=$(mktemp /tmp/xray_unblockuser_XXXXXX.json)
    if [ "$proto" = "trojan" ]; then
        jq -n --arg pwd "$real_cred" --arg em "$nick" \
            '{inbounds:[{tag:"inbound-turbonet",settings:{clients:[{password:$pwd,email:$em,level:0}]}}]}' > "$_tmp_api_json"
    elif [ "$preset_net" = "vision" ] || [ "${has_vision:-0}" -gt 0 ]; then
        jq -n --arg id "$real_cred" --arg em "$nick" \
            '{inbounds:[{tag:"inbound-turbonet",settings:{clients:[{id:$id,email:$em,level:0,flow:"xtls-rprx-vision"}]}}]}' > "$_tmp_api_json"
    else
        jq -n --arg id "$real_cred" --arg em "$nick" \
            '{inbounds:[{tag:"inbound-turbonet",settings:{clients:[{id:$id,email:$em,level:0}]}}]}' > "$_tmp_api_json"
    fi

    if /usr/local/bin/xray api adduser -s "127.0.0.1:${api_port}" "$_tmp_api_json" >>"$LOG_FILE" 2>&1; then
        rm -f "$_tmp_api_json"
        _tmp_api_json=""
        return 0
    fi

    rm -f "$_tmp_api_json"
    _tmp_api_json=""
    return 1
}

_fallback_reload() {
    if ! systemctl restart xray >>"$LOG_FILE" 2>&1 || ! _wait_xray_active; then
        echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
        mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        _apply_config_perms
        systemctl restart xray >/dev/null 2>&1 || true
        journalctl -u xray -n 15 --no-pager 2>/dev/null || true
        echo -e "${TXT_YELLOW}Config revertido.${RESET}"
        sleep 3; return 1
    fi
    return 0
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
            echo -e "${TXT_YELLOW}⚠  Conta Linux '${nick}' pertence ao sistema — não alterada.${RESET}"
            return 0
        fi
        usermod -U "$nick" 2>/dev/null || true
        chage -E -1 "$nick" 2>/dev/null || true
        passwd -u "$nick" 2>/dev/null || true
    fi
}

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
ensure_cmd jq jq
_apply_xraytools_perms

if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ config.json não encontrado.${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ config.json inválido (JSON corrompido).${RESET}"
    sleep 2; exit 1
fi
if [ ! -s "$USER_DB" ]; then
    echo -e "${TXT_RED}❌ users.db não encontrado ou vazio.${RESET}"
    sleep 2; exit 1
fi

clear
echo -e "${TXT_GREEN}🔓 DESBLOQUEAR USUÁRIO (REATIVAR)${RESET}"
echo ""

echo -e "${TXT_CYAN}--- Usuários Suspensos ---${RESET}"
locked_list="$(
    jq -r '
        .inbounds[]? | select(.tag=="inbound-turbonet")
        | .settings.clients[]?
        | select(.email? and (.email | startswith("LOCKED_")))
        | .email
    ' "$CONFIG_PATH" 2>/dev/null || true
)"

if [ -z "${locked_list:-}" ]; then
    echo "Nenhum usuário bloqueado no momento."
    echo "--------------------------"
    echo ""
    read -rp "Pressione Enter para voltar..."
    exit 0
fi

while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo " • ${line#LOCKED_}"
done <<< "$locked_list"
echo "--------------------------"
echo ""

read -rp "Usuário para desbloquear (0 para voltar): " user_input
[ "${user_input:-0}" = "0" ] || [ -z "${user_input:-}" ] && exit 0

if ! validate_nick "$user_input"; then
    echo -e "${TXT_RED}❌ Nick inválido. Use 5-9 letras/números.${RESET}"
    sleep 2; exit 1
fi

user_input=$(echo "$user_input" | tr '[:upper:]' '[:lower:]')

LOCKED_NAME="LOCKED_${user_input}"

if ! jq -e --arg lock "$LOCKED_NAME" '
    any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?; .email == $lock)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Usuário '${user_input}' não está na lista de bloqueados.${RESET}"
    sleep 2; exit 1
fi

echo "Recuperando dados originais..."
REAL_CRED="$(awk -F'|' -v u="$user_input" '$1==u {print $2; exit}' "$USER_DB" 2>/dev/null || true)"

if [ -z "${REAL_CRED:-}" ]; then
    echo -e "${TXT_RED}❌ Credencial original não encontrada em users.db.${RESET}"
    echo -e "${TXT_YELLOW}   O usuário pode ter sido removido do banco.${RESET}"
    sleep 3; exit 1
fi

if ! validate_credential "$REAL_CRED"; then
    echo -e "${TXT_RED}❌ Credencial no users.db está corrompida: '${REAL_CRED}'${RESET}"
    echo -e "${TXT_YELLOW}   Recrie o usuário com add_user.sh.${RESET}"
    sleep 3; exit 1
fi

echo ""
echo -e "${TXT_YELLOW}⚠  Reativar acesso de '${user_input}'?${RESET}"
read -rp "Confirmar? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

_tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

jq --arg nick   "$user_input" \
   --arg locked "$LOCKED_NAME" \
   --arg cred   "$REAL_CRED" '
    (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
        (if type == "array" then . else [] end)
    |
    (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
        map(if .email == $locked then
            .email = $nick
            | (if has("password") then .password = $cred else . end)
            | (if has("id") then .id = $cred else . end)
        else . end)
' "$CONFIG_PATH" > "$_tmp_cfg" 2>>"$LOG_FILE"

if ! jq empty "$_tmp_cfg" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Erro interno: JSON inválido gerado. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

if ! jq -e --arg nick "$user_input" --arg cred "$REAL_CRED" '
    any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?;
        .email == $nick and (.id == $cred or .password == $cred))
' "$_tmp_cfg" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Verificação pós-geração falhou: credencial não restaurada corretamente.${RESET}"
    sleep 2; exit 1
fi

mv -f "$_tmp_cfg" "$CONFIG_PATH"
_tmp_cfg=""
_apply_config_perms

# --- VALIDA SINTAXE E PERMISSÕES ANTES DE APLICAR ---
if ! _test_xray_config "$CONFIG_PATH" >>"$LOG_FILE" 2>&1; then
    echo -e "${TXT_RED}❌ Falha na validação do config.json pelo Xray. Revertendo...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    _apply_config_perms
    tail -n 10 "$LOG_FILE" 2>/dev/null || true
    sleep 3; exit 1
fi

# Aplica reativação (hot-reload via API interna com fallback para restart)
if _hot_reload_unblock_user "$user_input" "$LOCKED_NAME" "$REAL_CRED"; then
    echo -e "${TXT_GREEN}⚡ Credencial reativada via API sem derrubar conexões ativas.${RESET}"
else
    _fallback_reload || exit 1
fi

CRED_DISPLAY="${REAL_CRED:0:8}...${REAL_CRED: -4}"

# Desbloquear conta local automaticamente (SSH / Dropbear / SOCKS5)
_unlock_linux_account "$user_input"

echo ""
echo -e "${TXT_GREEN}✅ Usuário '${user_input}' reativado com sucesso!${RESET}"
echo -e " Credencial restaurada: ${TXT_CYAN}${CRED_DISPLAY}${RESET} (completa em users.db)"
echo -e " Prefixo ${TXT_YELLOW}LOCKED_${RESET} removido. Conexões normalizadas."
sleep 2
