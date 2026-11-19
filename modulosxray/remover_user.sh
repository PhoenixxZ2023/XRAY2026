#!/bin/bash
# remover_user.sh - TURBONET XRAY V1.1
# Correções aplicadas:
#   - Detecção dinâmica do usuário/grupo do xray.service (_detect_xray_owner)
#   - Permissões 750/640 root:$XRAY_GROUP aplicadas no diretório e no config.json
#   - Validação com `xray run -test` sob o usuário do serviço antes de reiniciar
#   - Substituído try-reload-or-restart por restart direto no fallback
#   - Suporte a credenciais Trojan (32 hex chars) além de nome e UUID

set -Eeuo pipefail

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"
CONN_INFO_DIR="/opt/XrayTools/users"
LOG_FILE="/tmp/remover_user.log"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- CLEANUP CENTRALIZADO ---
_tmp_cfg=""
_tmp_db=""
_cleanup() {
    [ -n "${_tmp_cfg:-}" ] && rm -f "$_tmp_cfg"
    [ -n "${_tmp_db:-}" ] && rm -f "$_tmp_db"
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

validate_identifier() {
    local id="$1"
    [[ "$id" =~ ^[a-zA-Z0-9]{5,9}$ ]] && return 0
    [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && return 0
    [[ "$id" =~ ^[0-9a-fA-F]{32}$ ]] && return 0
    return 1
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

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
ensure_cmd jq jq
mkdir -p "$(dirname "$USER_DB")" "$CONN_INFO_DIR"
[ -f "$USER_DB" ] || touch "$USER_DB"

if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ Config não encontrada: $CONFIG_PATH${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Config JSON inválido.${RESET}"
    sleep 2; exit 1
fi
if ! jq -e '.inbounds[]? | select(.tag=="inbound-turbonet")' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ inbound-turbonet não encontrado no config.${RESET}"
    sleep 2; exit 1
fi

# --- INTERFACE ---
clear
echo -e "${TITLE_BAR}   REMOVER USUÁRIO   ${RESET}"
echo ""

if [ -s "$USER_DB" ]; then
    echo -e "${TXT_CYAN}Usuários cadastrados:${RESET}"
    echo "-----------------------------------------"
    printf "%-12s %-14s %-12s\n" "NOME" "CREDENCIAL" "EXPIRA"
    echo "-----------------------------------------"
    while IFS='|' read -r name uuid expiry _rest; do
        printf "%-12s %-14s %-12s\n" "$name" "${uuid:0:8}..." "$expiry"
    done < "$USER_DB"
    echo "-----------------------------------------"
    echo ""
else
    echo -e "${TXT_YELLOW}Nenhum usuário cadastrado no DB.${RESET}"
    echo ""
fi

read -rp "Nome ou UUID/Senha para remover (0 para voltar): " identifier

[ "${identifier:-0}" = "0" ] || [ -z "${identifier:-}" ] && exit 0

if ! validate_identifier "$identifier"; then
    echo -e "${TXT_RED}❌ Identificador inválido. Use o nome (5-9 chars), UUID ou senha Trojan.${RESET}"
    sleep 2; exit 1
fi

identifier=$(echo "$identifier" | tr '[:upper:]' '[:lower:]')

# Confirma existência antes de agir
found_in_config=0
if jq -e --arg id "$identifier" '
    .inbounds[]? | select(.tag=="inbound-turbonet")
    | .settings.clients[]?
    | select(.id == $id or .password == $id or .email == $id)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    found_in_config=1
fi

found_in_db=0
if [ -s "$USER_DB" ] && \
   awk -F'|' -v id="$identifier" '($1==id || $2==id){found=1} END{exit found?0:1}' "$USER_DB" 2>/dev/null; then
    found_in_db=1
fi

if [ "$found_in_config" -eq 0 ] && [ "$found_in_db" -eq 0 ]; then
    echo -e "${TXT_RED}❌ Nenhum usuário encontrado com: '${identifier}'${RESET}"
    sleep 2; exit 0
fi

# Resolve nome real para limpeza do arquivo de info e SSH
nick_real=""
if [ "$found_in_db" -eq 1 ] && [ -s "$USER_DB" ]; then
    nick_real=$(awk -F'|' -v id="$identifier" '($1==id || $2==id){print $1; exit}' "$USER_DB" 2>/dev/null || echo "")
fi
if [ -z "$nick_real" ] && [ "$found_in_config" -eq 1 ]; then
    nick_real=$(jq -r --arg id "$identifier" '
        .inbounds[]? | select(.tag=="inbound-turbonet")
        | .settings.clients[]?
        | select(.id == $id or .password == $id or .email == $id)
        | .email // ""
    ' "$CONFIG_PATH" 2>/dev/null | head -1 || echo "")
fi

# Confirmação explícita
echo ""
echo -e "${TXT_YELLOW}⚠  Remover usuário: '${nick_real:-$identifier}'?${RESET}"
read -rp "Confirmar? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

# --- BACKUP DO CONFIG ---
cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

# --- APLICA REMOÇÃO NO CONFIG ---
_tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

jq --arg id "$identifier" '
  (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
    (if type == "array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
    map(select(.id != $id and .password != $id and .email != $id))
' "$CONFIG_PATH" > "$_tmp_cfg"

if ! jq empty "$_tmp_cfg" 2>/dev/null; then
    echo -e "${TXT_RED}❌ jq gerou JSON inválido. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

before_count=$(jq '[.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?] | length' "$CONFIG_PATH" 2>/dev/null || echo 0)
after_count=$(jq  '[.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?] | length' "$_tmp_cfg"    2>/dev/null || echo 0)

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

# Hot reload: remove via API (sem restart). Fallback: restart do serviço.
target_email="${nick_real:-$identifier}"
if _api_remove "$target_email" 2>/dev/null; then
    echo -e "${TXT_GREEN}Removido via API (sem restart).${RESET}"
else
    echo -e "${TXT_YELLOW}Aplicando remoção via reinício do Xray...${RESET}"
    _fallback_reload || exit 1
fi

# --- SÓ AGORA ATUALIZA O DB (após aplicação confirmada) ---
if [ "$found_in_db" -eq 1 ] && [ -s "$USER_DB" ]; then
    _tmp_db=$(mktemp "${USER_DB}.tmp.XXXXXX")
    awk -F'|' -v id="$identifier" '($1!=id && $2!=id){print $0}' "$USER_DB" > "$_tmp_db"
    mv -f "$_tmp_db" "$USER_DB"
    _tmp_db=""
    chmod 600 "$USER_DB"
fi

file_removed=0
if [ -n "$nick_real" ]; then
    user_file="${CONN_INFO_DIR}/${nick_real}.txt"
    if [ -f "$user_file" ]; then
        rm -f "$user_file"
        file_removed=1
    fi
fi

# --- INTEGRAÇÃO SSH: REMOVER USUÁRIO DO SISTEMA (Dropbear/SOCKS5) ---
ssh_removed=0
if [ -n "$nick_real" ] && id "$nick_real" &>/dev/null; then
    userdel -f "$nick_real" 2>/dev/null || true
    ssh_removed=1
fi

# --- RESULTADO ---
removed_config=$(( before_count - after_count ))

clear
if [ "$removed_config" -gt 0 ] || [ "$found_in_db" -eq 1 ]; then
    echo -e "${TXT_GREEN}✅ Usuário '${nick_real:-$identifier}' removido com sucesso.${RESET}"
    echo "-----------------------------------------"
    [ "$removed_config" -gt 0 ] && echo -e " Config:   ${TXT_GREEN}removido do Xray${RESET}"
    [ "$found_in_db"    -eq 1 ] && echo -e " DB:       ${TXT_GREEN}removido do banco${RESET}"
    [ "$file_removed"   -eq 1 ] && echo -e " Arquivo:  ${TXT_GREEN}${CONN_INFO_DIR}/${nick_real}.txt apagado${RESET}"
    [ "$ssh_removed"    -eq 1 ] && echo -e " SSH/SOCKS:${TXT_GREEN} acesso local bloqueado${RESET}"
    echo "-----------------------------------------"
else
    echo -e "${TXT_RED}⚠  Nenhum dado removido (usuário não estava no config).${RESET}"
fi

sleep 1
read -rp "Enter para voltar..."
