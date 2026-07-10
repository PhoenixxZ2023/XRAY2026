#!/bin/bash
# unblock_user.sh - TURBONET XRAY V1.0
# Correções aplicadas:
#   - _apply_config_perms() centralizada (640 root:nogroup para hardening)
#   - _cleanup() + trap EXIT desde o início
#   - _wait_xray_active() com retry de 5s
#   - user_input normalizado para minúsculas
#   - Verificação extra do UUID restaurado no JSON antes do restart

set -Eeuo pipefail

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LOG_FILE="/tmp/unblock_user.log"

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- CLEANUP CENTRALIZADO ---
_tmp_cfg=""
_cleanup() {
    rm -f "$_tmp_cfg"
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

# --- PERMISSÕES DO CONFIG ---
# Ajustado para 640 root:nogroup (leitura para o grupo, escrita apenas para root)
_apply_config_perms() {
    chmod 0640 "$CONFIG_PATH"
    chown root:nogroup "$CONFIG_PATH"
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

validate_uuid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
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
    echo -e "${TXT_RED}❌ config.json inválido.${RESET}"
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
REAL_UUID="$(awk -F'|' -v u="$user_input" '$1==u {print $2; exit}' "$USER_DB" 2>/dev/null || true)"

if [ -z "${REAL_UUID:-}" ]; then
    echo -e "${TXT_RED}❌ UUID original não encontrado em users.db.${RESET}"
    sleep 3; exit 1
fi

if ! validate_uuid "$REAL_UUID"; then
    echo -e "${TXT_RED}❌ UUID no users.db está corrompido.${RESET}"
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
   --arg uuid   "$REAL_UUID" '
    (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
        (if type == "array" then . else [] end)
    |
    (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
        map(if .email == $locked then .email = $nick | .id = $uuid else . end)
' "$CONFIG_PATH" > "$_tmp_cfg" 2>>"$LOG_FILE"

if ! jq empty "$_tmp_cfg" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Erro interno: JSON inválido.${RESET}"
    sleep 2; exit 1
fi

if ! jq -e --arg nick "$user_input" --arg uuid "$REAL_UUID" '
    any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?;
        .email == $nick and .id == $uuid)
' "$_tmp_cfg" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Falha na verificação de integridade pós-desbloqueio.${RESET}"
    sleep 2; exit 1
fi

mv -f "$_tmp_cfg" "$CONFIG_PATH"
_tmp_cfg=""
_apply_config_perms

# --- HELPER: API ---
_xray_api_port() {
    jq -r '.inbounds[]? | select(.tag=="api") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1
}
_api_remove() {
    local email="$1"
    local p; p=$(_xray_api_port); [ -z "${p:-}" ] && return 1
    /usr/local/bin/xray api removeuser -server="127.0.0.1:${p}" \
        -inboundTag="inbound-turbonet" -email="$email" >/dev/null 2>&1
}
_api_add() {
    local email="$1" id="$2"
    local p; p=$(_xray_api_port); [ -z "${p:-}" ] && return 1
    local uj; uj=$(jq -n --arg id "$id" --arg e "$email" '{"id":$id,"email":$e,"level":0}')
    /usr/local/bin/xray api adduser -server="127.0.0.1:${p}" \
        -inboundTag="inbound-turbonet" -user="$uj" >/dev/null 2>&1
}

if _api_remove "LOCKED_${user_input}" && _api_add "$user_input" "$REAL_UUID"; then
    echo -e "${TXT_GREEN}Reativado via API.${RESET}"
else
    echo -e "${TXT_YELLOW}API indisponível — recarregando serviço...${RESET}"
    systemctl restart xray >/dev/null 2>&1 || true
fi

echo -e "${TXT_GREEN}✅ Usuário '${user_input}' reativado com sucesso!${RESET}"
sleep 2
