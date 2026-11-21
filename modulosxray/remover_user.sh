#!/bin/bash
# remover_user.sh - TURBONET XRAY V1.2 (PRO + Compatibilidade Bot Telegram)
# Atualizações V1.2:
#   - _apply_config_perms e _apply_xraytools_perms preservam permissões 2770/0660 quando o usuário `botxray` existe
#   - Remove corretamente usuários ativos e suspensos (`LOCKED_<nick>`) tanto por nome quanto por UUID/senha
#   - Corrigida sintaxe da API interna (`xray api removeuser -email=...`) para hot-reload sem derrubar conexões ativas
#   - Limpa também registros em limits.db e usage.db preservando dono/permissões
#   - Valida UID >= 1000 e shell /bin/false antes de remover conta Linux local

set -Eeuo pipefail

CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
XRAYTOOLS_DIR="/opt/XrayTools"
USER_DB="${XRAYTOOLS_DIR}/users.db"
LIMITS_DB="${XRAYTOOLS_DIR}/limits.db"
USAGE_DB="${XRAYTOOLS_DIR}/usage.db"
CONN_INFO_DIR="${XRAYTOOLS_DIR}/users"
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

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
fi

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

_apply_xraytools_perms() {
    mkdir -p "$XRAYTOOLS_DIR" "$CONN_INFO_DIR"
    if id -u botxray &>/dev/null; then
        chown root:botxray "$XRAYTOOLS_DIR"
        chmod 2770 "$XRAYTOOLS_DIR"

        chown root:botxray "$CONN_INFO_DIR"
        chmod 0750 "$CONN_INFO_DIR"

        for db in "$USER_DB" "$LIMITS_DB" "$USAGE_DB"; do
            if [ -f "$db" ]; then
                chown botxray:botxray "$db"
                chmod 0660 "$db"
            fi
        done
    else
        chmod 0750 "$XRAYTOOLS_DIR"
        chmod 0700 "$CONN_INFO_DIR"
        for db in "$USER_DB" "$LIMITS_DB" "$USAGE_DB"; do
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

_clean_db_entry() {
    local db_file="$1" nick_match="$2" id_match="$3"
    [ -s "$db_file" ] || return 0
    _tmp_db=$(mktemp "${db_file}.tmp.XXXXXX")
    awk -F'|' -v n="$nick_match" -v id="$id_match" \
        '($1 != n && $1 != id && $2 != id){print $0}' "$db_file" > "$_tmp_db"
    mv -f "$_tmp_db" "$db_file"
    _tmp_db=""
}

_remove_linux_account() {
    local nick="$1"
    [ -n "$nick" ] || return 1
    if getent passwd "$nick" >/dev/null 2>&1; then
        local uid shell
        uid=$(id -u "$nick" 2>/dev/null || echo 0)
        shell=$(getent passwd "$nick" | cut -d: -f7)
        if [ "$uid" -lt 1000 ] || [ "$shell" != "/bin/false" ]; then
            echo -e "${TXT_YELLOW}⚠  Conta Linux '${nick}' pertence ao sistema — não removida.${RESET}"
            return 1
        fi
        pkill -KILL -u "$nick" 2>/dev/null || true
        userdel -r -f "$nick" 2>/dev/null || true
        return 0
    fi
    return 1
}

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
ensure_cmd jq jq
mkdir -p "$XRAYTOOLS_DIR" "$CONN_INFO_DIR"
[ -f "$USER_DB" ] || touch "$USER_DB"
_apply_xraytools_perms

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
        [ -z "${name:-}" ] && continue
        printf "%-12s %-14s %-12s\n" "$name" "${uuid:0:8}..." "${expiry:-N/A}"
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

# Resolve nome real no DB ou no config (inclusive se estiver LOCKED_)
found_in_db=0
nick_real=""
if [ -s "$USER_DB" ]; then
    nick_real=$(awk -F'|' -v id="$identifier" '($1==id || $2==id){print $1; exit}' "$USER_DB" 2>/dev/null || echo "")
    [ -n "$nick_real" ] && found_in_db=1
fi

found_in_config=0
if jq -e --arg id "$identifier" --arg nick "${nick_real:-$identifier}" '
    .inbounds[]? | select(.tag=="inbound-turbonet")
    | .settings.clients[]?
    | select(
        .id == $id or .password == $id or
        .email == $id or .email == ("LOCKED_" + $id) or
        .email == $nick or .email == ("LOCKED_" + $nick)
      )
' "$CONFIG_PATH" >/dev/null 2>&1; then
    found_in_config=1
fi

if [ "$found_in_config" -eq 0 ] && [ "$found_in_db" -eq 0 ]; then
    echo -e "${TXT_RED}❌ Nenhum usuário encontrado com: '${identifier}'${RESET}"
    sleep 2; exit 0
fi

if [ -z "$nick_real" ] && [ "$found_in_config" -eq 1 ]; then
    raw_email=$(jq -r --arg id "$identifier" '
        .inbounds[]? | select(.tag=="inbound-turbonet")
        | .settings.clients[]?
        | select(.id == $id or .password == $id or .email == $id or .email == ("LOCKED_" + $id))
        | .email // ""
    ' "$CONFIG_PATH" 2>/dev/null | head -1 || echo "")
    nick_real="${raw_email#LOCKED_}"
fi

clean_nick="${nick_real:-$identifier}"

# Confirmação explícita
echo ""
echo -e "${TXT_YELLOW}⚠  Remover usuário: '${clean_nick}'?${RESET}"
read -rp "Confirmar? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

# --- BACKUP DO CONFIG ---
cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

# --- APLICA REMOÇÃO NO CONFIG (ATIVOS E BLOQUEADOS) ---
_tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

jq --arg id "$identifier" --arg nick "$clean_nick" '
  (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
    (if type == "array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
    map(select(
      .id != $id and .password != $id and
      .email != $id and .email != ("LOCKED_" + $id) and
      .email != $nick and .email != ("LOCKED_" + $nick)
    ))
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

# --- HELPER: porta e remoção via API do Xray ---
_xray_api_port() {
    jq -r '.inbounds[]? | select(.tag=="api" or .protocol=="dokodemo-door") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1
}

_api_remove() {
    local email="$1"
    [ ! -x /usr/local/bin/xray ] && return 1
    systemctl is-active --quiet xray 2>/dev/null || return 1
    local p; p=$(_xray_api_port); [ -z "${p:-}" ] && return 1
    /usr/local/bin/xray api removeuser \
        -server="127.0.0.1:${p}" \
        -inboundTag="inbound-turbonet" \
        -email="$email" >>"$LOG_FILE" 2>&1
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

# Hot reload: remove via API (ativo ou LOCKED_). Fallback: restart do serviço.
if _api_remove "$clean_nick" || _api_remove "LOCKED_${clean_nick}"; then
    echo -e "${TXT_GREEN}⚡ Removido via API sem derrubar conexões ativas.${RESET}"
else
    echo -e "${TXT_YELLOW}Aplicando remoção via reinício do Xray...${RESET}"
    _fallback_reload || exit 1
fi

# --- ATUALIZA OS BANCOS DE DADOS APÓS APLICAÇÃO CONFIRMADA ---
_clean_db_entry "$USER_DB"   "$clean_nick" "$identifier"
_clean_db_entry "$LIMITS_DB" "$clean_nick" "$identifier"
_clean_db_entry "$USAGE_DB"  "$clean_nick" "$identifier"
_apply_xraytools_perms

file_removed=0
if [ -n "$clean_nick" ]; then
    user_file="${CONN_INFO_DIR}/${clean_nick}.txt"
    if [ -f "$user_file" ]; then
        rm -f "$user_file"
        file_removed=1
    fi
fi

# --- INTEGRAÇÃO SSH: REMOVER USUÁRIO DO SISTEMA (SSH/Dropbear/SOCKS5) ---
ssh_removed=0
if _remove_linux_account "$clean_nick"; then
    ssh_removed=1
fi

# --- RESULTADO ---
removed_config=$(( before_count - after_count ))

clear
if [ "$removed_config" -gt 0 ] || [ "$found_in_db" -eq 1 ]; then
    echo -e "${TXT_GREEN}✅ Usuário '${clean_nick}' removido com sucesso.${RESET}"
    echo "-----------------------------------------"
    [ "$removed_config" -gt 0 ] && echo -e " Config:    ${TXT_GREEN}removido do Xray${RESET}"
    [ "$found_in_db"    -eq 1 ] && echo -e " DB:        ${TXT_GREEN}removido do banco${RESET}"
    [ "$file_removed"   -eq 1 ] && echo -e " Arquivo:   ${TXT_GREEN}${CONN_INFO_DIR}/${clean_nick}.txt apagado${RESET}"
    [ "$ssh_removed"    -eq 1 ] && echo -e " SSH/SOCKS: ${TXT_GREEN}conta local removida${RESET}"
    echo "-----------------------------------------"
else
    echo -e "${TXT_RED}⚠  Nenhum dado removido (usuário não estava no config).${RESET}"
fi

sleep 1
read -rp "Enter para voltar..."
