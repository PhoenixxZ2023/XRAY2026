#!/bin/bash
# remover_expirados.sh - TURBONET XRAY V1.2 (PRO + Hot-Reload API + Compatibilidade Bot Telegram)
# Atualizações V1.2:
#   - _apply_config_perms e _apply_xraytools_perms preservam permissões 2770/0660 quando o usuário `botxray` existe
#   - Hot-reload via API interna (`xray api removeuser -email=...`) sem derrubar clientes ativos, com fallback para restart
#   - Limpeza completa também em limits.db, usage.db e session.db com lock compartilhado (`flock`)
#   - Validação de UID >= 1000 e shell /bin/false + pkill antes de remover conta Linux local
#   - Verificação explícita de root (EUID) e suporte opcional ao parâmetro `--auto` para agendamento no cron

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
LIMITS_DB="${XRAYTOOLS_DIR}/limits.db"
USAGE_DB="${XRAYTOOLS_DIR}/usage.db"
SESSION_DB="${XRAYTOOLS_DIR}/session.db"
CONN_INFO_DIR="${XRAYTOOLS_DIR}/users"
CONFIG_PATH="/usr/local/etc/xray/config.json"
PRESET_FILE="/usr/local/etc/xray/preset.json"
XRAY_BIN="/usr/local/bin/xray"
LOG_FILE="/tmp/remover_expirados.log"
LOCK_FILE="/tmp/limiterxray.lock"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_YELLOW='\033[1;33m'
TXT_CYAN='\033[1;36m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

AUTO_MODE=0
if [ "${1:-}" = "--auto" ] || [ "${1:-}" = "--cron" ]; then
    AUTO_MODE=1
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    [ "$AUTO_MODE" -eq 0 ] && echo -e "${TXT_RED}❌ Execute como root!${RESET}"
    exit 1
fi

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

        for db in "$USER_DB" "$LIMITS_DB" "$USAGE_DB" "$SESSION_DB"; do
            if [ -f "$db" ]; then
                chown botxray:botxray "$db"
                chmod 0660 "$db"
            fi
        done
    else
        chmod 0750 "$XRAYTOOLS_DIR"
        chmod 0700 "$CONN_INFO_DIR"
        for db in "$USER_DB" "$LIMITS_DB" "$USAGE_DB" "$SESSION_DB"; do
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

# --- COMPARAÇÃO DE DATA ROBUSTA ---
# Retorna 0 se $1 (YYYY-MM-DD) já venceu (anterior à data atual)
is_expired() {
    local expiry="$1"
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    local exp_ts today_ts
    exp_ts=$(date -d "$expiry" +%s 2>/dev/null) || return 1
    today_ts=$(date -d "$(date +%F)" +%s)
    [ "$exp_ts" -lt "$today_ts" ]
}

# --- VERIFICAÇÃO DE XRAY ATIVO E API INTERNA ---
_wait_xray_active() {
    local tries=5
    while [ "$tries" -gt 0 ]; do
        systemctl is-active --quiet xray 2>/dev/null && return 0
        sleep 1
        tries=$((tries - 1))
    done
    return 1
}

_xray_api_port() {
    jq -r '.inbounds[]? | select(.tag=="api" or .protocol=="dokodemo-door") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1
}

_hot_reload_remove_expired() {
    local emails_file="$1"
    [ ! -x "$XRAY_BIN" ] && return 1
    systemctl is-active --quiet xray 2>/dev/null || return 1

    local api_port
    api_port=$(_xray_api_port)
    [ -z "${api_port:-}" ] && return 1

    # Verifica se o servidor gRPC da API está respondendo antes de confiar no hot-reload
    timeout 3 "$XRAY_BIN" api statsquery -server="127.0.0.1:${api_port}" >/dev/null 2>&1 || return 1

    while IFS= read -r em; do
        [ -n "$em" ] || continue
        timeout 3 "$XRAY_BIN" api removeuser \
            -server="127.0.0.1:${api_port}" \
            -inboundTag="inbound-turbonet" \
            -email="$em" >>"$LOG_FILE" 2>&1 || true
    done < "$emails_file"

    return 0
}

_remove_linux_account() {
    local nick="$1"
    [ -n "$nick" ] || return 0
    if getent passwd "$nick" >/dev/null 2>&1; then
        local uid shell
        uid=$(id -u "$nick" 2>/dev/null || echo 0)
        shell=$(getent passwd "$nick" | cut -d: -f7)
        if [ "$uid" -lt 1000 ] || [ "$shell" != "/bin/false" ]; then
            [ "$AUTO_MODE" -eq 0 ] && echo -e " ${TXT_YELLOW}⚠ Conta Linux '${nick}' pertence ao sistema — não removida.${RESET}"
            return 0
        fi
        pkill -KILL -u "$nick" 2>/dev/null || true
        userdel -r -f "$nick" 2>/dev/null || true
    fi
}

# --- INICIALIZAÇÃO ---
: > "$LOG_FILE"
ensure_cmd jq jq
_apply_xraytools_perms

if [ "$AUTO_MODE" -eq 0 ]; then
    clear
    echo -e "${TITLE_BAR}   LIMPEZA DE EXPIRADOS (V1.2 PRO)   ${RESET}"
    echo ""
fi

if [ ! -f "$USER_DB" ] || [ ! -s "$USER_DB" ]; then
    if [ "$AUTO_MODE" -eq 0 ]; then
        echo "Banco de dados vazio ou inexistente."
        read -rp "Enter para voltar..."
    fi
    exit 0
fi
if [ ! -s "$CONFIG_PATH" ]; then
    [ "$AUTO_MODE" -eq 0 ] && { echo -e "${TXT_RED}❌ config.json não encontrado.${RESET}"; read -rp "Enter para voltar..."; }
    exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    [ "$AUTO_MODE" -eq 0 ] && { echo -e "${TXT_RED}❌ config.json inválido.${RESET}"; read -rp "Enter para voltar..."; }
    exit 1
fi
if ! jq -e '.inbounds[]? | select(.tag=="inbound-turbonet")' "$CONFIG_PATH" >/dev/null 2>&1; then
    [ "$AUTO_MODE" -eq 0 ] && { echo -e "${TXT_RED}❌ inbound-turbonet não encontrado no config.${RESET}"; read -rp "Enter para voltar..."; }
    exit 1
fi

if [ "$AUTO_MODE" -eq 0 ]; then
    echo -e "${TXT_YELLOW}Verificando vencimentos...${RESET}"
    echo ""
    printf "%-20s | %s\n" "USUÁRIO" "VENCIMENTO"
    echo "-----------------------------------"
fi

expired_creds_file=$(mktemp /tmp/expired_creds_XXXXXX)
expired_nicks_file=$(mktemp /tmp/expired_nicks_XXXXXX)
expired_emails_file=$(mktemp /tmp/expired_emails_XXXXXX)
_TMP_FILES+=("$expired_creds_file" "$expired_nicks_file" "$expired_emails_file")

count=0
while IFS='|' read -r nick uuid expiry _rest; do
    [ -n "${nick:-}" ] && [ -n "${uuid:-}" ] || continue
    if is_expired "${expiry:-}"; then
        [ "$AUTO_MODE" -eq 0 ] && printf "${TXT_RED}%-20s${RESET} | ${TXT_RED}%s${RESET}\n" "$nick" "${expiry:-sem data}"
        echo "$uuid" >> "$expired_creds_file"
        echo "$nick" >> "$expired_nicks_file"
        echo "$nick" >> "$expired_emails_file"
        echo "LOCKED_${nick}" >> "$expired_emails_file"
        count=$(( count + 1 ))
    fi
done < "$USER_DB"

if [ "$AUTO_MODE" -eq 0 ]; then
    echo "-----------------------------------"
    echo ""
fi

if [ "$count" -eq 0 ]; then
    if [ "$AUTO_MODE" -eq 0 ]; then
        echo -e "${TXT_GREEN}✅ Nenhum usuário vencido.${RESET}"
        read -rp "Enter para voltar..."
    fi
    exit 0
fi

if [ "$AUTO_MODE" -eq 0 ]; then
    echo -e "Encontrados ${TXT_RED}${count}${RESET} usuário(s) vencido(s)."
    read -rp "Excluir agora? [s/N]: " confirm
    [[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }
fi

exec 9>"$LOCK_FILE"
flock -w 10 9 || true

# --- PASSO 1: MODIFICA CONFIG ---
expired_creds_json=$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$expired_creds_file")
expired_emails_json=$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$expired_emails_file")

cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
_TMP_FILES+=("$tmp_cfg")

jq --argjson dead_creds  "$expired_creds_json" \
   --argjson dead_emails "$expired_emails_json" '
  (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
    (if type == "array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
    map(select(
      ((.id // "") as $id | ($dead_creds | index($id)) == null) and
      ((.password // "") as $pwd | ($dead_creds | index($pwd)) == null) and
      ((.email // "") as $em | ($dead_emails | index($em)) == null)
    ))
' "$CONFIG_PATH" > "$tmp_cfg" 2>>"$LOG_FILE"

if ! jq empty "$tmp_cfg" 2>/dev/null; then
    [ "$AUTO_MODE" -eq 0 ] && echo -e "${TXT_RED}❌ JSON inválido gerado. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

mv -f "$tmp_cfg" "$CONFIG_PATH"
_TMP_FILES=("${_TMP_FILES[@]/$tmp_cfg}")
_apply_config_perms

# --- PASSO 2: VALIDAÇÃO E APLICAÇÃO (HOT-RELOAD COM FALLBACK) ---
if ! _test_xray_config "$CONFIG_PATH" >>"$LOG_FILE" 2>&1; then
    [ "$AUTO_MODE" -eq 0 ] && echo -e "${TXT_RED}❌ Falha na validação do config.json pelo Xray. Revertendo...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    _apply_config_perms
    [ "$AUTO_MODE" -eq 0 ] && tail -n 10 "$LOG_FILE" 2>/dev/null || true
    sleep 3; exit 1
fi

if _hot_reload_remove_expired "$expired_emails_file"; then
    [ "$AUTO_MODE" -eq 0 ] && echo -e "${TXT_GREEN}⚡ Expirados removidos via API sem derrubar conexões ativas.${RESET}"
else
    [ "$AUTO_MODE" -eq 0 ] && echo -e "Reiniciando Xray..."
    if ! systemctl restart xray >>"$LOG_FILE" 2>&1 || ! _wait_xray_active; then
        [ "$AUTO_MODE" -eq 0 ] && echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
        mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        _apply_config_perms
        systemctl restart xray >/dev/null 2>&1 || true
        [ "$AUTO_MODE" -eq 0 ] && {
            journalctl -u xray -n 15 --no-pager 2>/dev/null || true
            echo -e "${TXT_YELLOW}Config revertido. Nenhum usuário foi removido.${RESET}"
        }
        sleep 3; exit 1
    fi
fi

# --- PASSO 3: ATUALIZA O DB PRESERVANDO TODAS AS COLUNAS ---
tmp_db=$(mktemp "${USER_DB}.tmp.XXXXXX")
_TMP_FILES+=("$tmp_db")

awk -F'|' -v auto="$AUTO_MODE" '
    NR==FNR { expired[$1]=1; next }
    NF > 0 {
        if ($1 in expired) {
            if (auto == 0) print " \033[1;31mRemovido DB:\033[0m " $1 > "/dev/stderr"
        } else {
            print $0
        }
    }
' "$expired_nicks_file" "$USER_DB" > "$tmp_db"

mv -f "$tmp_db" "$USER_DB"
_TMP_FILES=("${_TMP_FILES[@]/$tmp_db}")

# --- PASSO 3b: LIMPA LIMITS.DB, USAGE.DB E SESSION.DB ---
for aux_db in "$LIMITS_DB" "$USAGE_DB" "$SESSION_DB"; do
    if [ -s "$aux_db" ] && [ -s "$expired_nicks_file" ]; then
        tmp_aux=$(mktemp "${aux_db}.tmp.XXXXXX")
        _TMP_FILES+=("$tmp_aux")
        awk -F'|' 'NR==FNR { expired[$1]=1; next } !($1 in expired) { print $0 }' "$expired_nicks_file" "$aux_db" > "$tmp_aux"
        mv -f "$tmp_aux" "$aux_db"
        _TMP_FILES=("${_TMP_FILES[@]/$tmp_aux}")
    fi
done

_apply_xraytools_perms

# --- PASSO 3c: REMOVE USUÁRIOS LOCAIS (SSH / DROPBEAR / SOCKS5) ---
if [ -s "$expired_nicks_file" ]; then
    while IFS= read -r enick; do
        [ -n "$enick" ] || continue
        _remove_linux_account "$enick"
    done < "$expired_nicks_file"
fi

# --- PASSO 4: LIMPA ARQUIVOS DE INFO ---
if [ -d "$CONN_INFO_DIR" ] && [ -s "$expired_nicks_file" ]; then
    while IFS= read -r nick; do
        [ -n "$nick" ] || continue
        local_info="${CONN_INFO_DIR}/${nick}.txt"
        if [ -f "$local_info" ]; then
            rm -f "$local_info"
            [ "$AUTO_MODE" -eq 0 ] && echo -e " ${TXT_CYAN}Arquivo removido:${RESET} ${nick}.txt"
        fi
    done < "$expired_nicks_file"
fi

flock -u 9 2>/dev/null || true

if [ "$AUTO_MODE" -eq 0 ]; then
    echo ""
    echo -e "${TXT_GREEN}✅ Limpeza concluída: ${count} usuário(s) removido(s).${RESET}"
    read -rp "Enter para voltar..."
fi
