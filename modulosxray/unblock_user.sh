#!/bin/bash
# unblock_user.sh - TURBONET XRAY V1.1
# Correções aplicadas:
#   - Detecção dinâmica do usuário/grupo do xray.service (_detect_xray_owner)
#   - Permissões 750/640 root:$XRAY_GROUP aplicadas no diretório e no config.json
#   - Validação com `xray run -test` sob o usuário do serviço antes de reiniciar
#   - Substituído try-reload-or-restart por restart direto no fallback
#   - Suporte completo a credenciais Trojan (32 hex chars em .password) além de UUID
#   - Desbloqueio da conta Linux para Dropbear e SOCKS5

set -Eeuo pipefail

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LOG_FILE="/tmp/unblock_user.log"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- CLEANUP CENTRALIZADO ---
_tmp_cfg=""
_cleanup() {
    [ -n "${_tmp_cfg:-}" ] && rm -f "$_tmp_cfg"
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

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
ensure_cmd jq jq

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

# --- HELPER: porta da API do Xray ---
_xray_api_port() {
    jq -r '.inbounds[]? | select(.tag=="api" or .protocol=="dokodemo-door") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1
}
_api_remove() {
    local email="$1"
    systemctl is-active --quiet xray 2>/dev/null || return 1
    local p; p=$(_xray_api_port); [ -z "${p:-}" ] && return 1
    /usr/local/bin/xray api rmu -server="127.0.0.1:${p}" \
        -inboundTag="inbound-turbonet" "$email" >/dev/null 2>&1
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

# Remove sessão bloqueada via API e reinicia para efetivar credencial original
_api_remove "LOCKED_${user_input}" 2>/dev/null || true
_fallback_reload || exit 1

CRED_DISPLAY="${REAL_CRED:0:8}...${REAL_CRED: -4}"

# Desbloquear conta local automaticamente (Dropbear / SOCKS5)
if id "$user_input" &>/dev/null; then
    passwd -u "$user_input" 2>/dev/null || true
fi

echo ""
echo -e "${TXT_GREEN}✅ Usuário '${user_input}' reativado com sucesso!${RESET}"
echo -e " Credencial restaurada: ${TXT_CYAN}${CRED_DISPLAY}${RESET} (completa em users.db)"
echo -e " Prefixo ${TXT_YELLOW}LOCKED_${RESET} removido. Conexões normalizadas."
sleep 2
