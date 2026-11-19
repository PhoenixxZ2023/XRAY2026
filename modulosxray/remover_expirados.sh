#!/bin/bash
# remover_expirados.sh - TURBONET XRAY V1.1
# Correções aplicadas:
#   - Preserva todas as colunas do users.db (senha SSH/SOCKS5 e limite) ao filtrar ativos
#   - Remove também usuários expirados que estavam bloqueados (LOCKED_) ou em modo Trojan (.password)
#   - Detecção dinâmica do usuário/grupo do xray.service (_detect_xray_owner)
#   - Permissões 750/640 root:$XRAY_GROUP aplicadas no diretório e no config.json
#   - Validação com `xray run -test` sob o usuário do serviço antes de reiniciar
#   - Limpeza de contas locais (Dropbear/SOCKS5) e registros em usage.db/session.db

set -Eeuo pipefail

# --- CLEANUP CENTRALIZADO ---
_TMP_FILES=()
_cleanup() {
    for f in "${_TMP_FILES[@]:-}"; do
        [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
    done
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
USAGE_DB="/opt/XrayTools/usage.db"
SESSION_DB="/opt/XrayTools/session.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
CONN_INFO_DIR="/opt/XrayTools/users"
XRAY_BIN="/usr/local/bin/xray"
LOG_FILE="/tmp/remover_expirados.log"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_YELLOW='\033[1;33m'
TXT_CYAN='\033[1;36m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

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

clear
echo -e "${TITLE_BAR}   LIMPEZA DE EXPIRADOS   ${RESET}"
echo ""

if [ ! -f "$USER_DB" ] || [ ! -s "$USER_DB" ]; then
    echo "Banco de dados vazio ou inexistente."
    read -rp "Enter para voltar..."; exit 0
fi
if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ config.json não encontrado.${RESET}"
    read -rp "Enter para voltar..."; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ config.json inválido.${RESET}"
    read -rp "Enter para voltar..."; exit 1
fi
if ! jq -e '.inbounds[]? | select(.tag=="inbound-turbonet")' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ inbound-turbonet não encontrado no config.${RESET}"
    read -rp "Enter para voltar..."; exit 1
fi

echo -e "${TXT_YELLOW}Verificando vencimentos...${RESET}"
echo ""
printf "%-20s | %s\n" "USUÁRIO" "VENCIMENTO"
echo "-----------------------------------"

expired_creds_file=$(mktemp /tmp/expired_creds_XXXXXX)
expired_nicks_file=$(mktemp /tmp/expired_nicks_XXXXXX)
expired_emails_file=$(mktemp /tmp/expired_emails_XXXXXX)
_TMP_FILES+=("$expired_creds_file" "$expired_nicks_file" "$expired_emails_file")

count=0
while IFS='|' read -r nick uuid expiry _rest; do
    [ -n "${nick:-}" ] && [ -n "${uuid:-}" ] || continue
    if is_expired "${expiry:-}"; then
        printf "${TXT_RED}%-20s${RESET} | ${TXT_RED}%s${RESET}\n" "$nick" "${expiry:-sem data}"
        echo "$uuid" >> "$expired_creds_file"
        echo "$nick" >> "$expired_nicks_file"
        echo "$nick" >> "$expired_emails_file"
        echo "LOCKED_${nick}" >> "$expired_emails_file"
        count=$(( count + 1 ))
    fi
done < "$USER_DB"

echo "-----------------------------------"
echo ""

if [ "$count" -eq 0 ]; then
    echo -e "${TXT_GREEN}✅ Nenhum usuário vencido.${RESET}"
    read -rp "Enter para voltar..."; exit 0
fi

echo -e "Encontrados ${TXT_RED}${count}${RESET} usuário(s) vencido(s)."
read -rp "Excluir agora? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

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
    echo -e "${TXT_RED}❌ JSON inválido gerado. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

mv -f "$tmp_cfg" "$CONFIG_PATH"
_TMP_FILES=("${_TMP_FILES[@]/$tmp_cfg}")
_apply_config_perms

# --- PASSO 2: VALIDAÇÃO E RESTART ---
if ! _test_xray_config "$CONFIG_PATH" >>"$LOG_FILE" 2>&1; then
    echo -e "${TXT_RED}❌ Falha na validação do config.json pelo Xray. Revertendo...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    _apply_config_perms
    tail -n 10 "$LOG_FILE" 2>/dev/null || true
    sleep 3; exit 1
fi

echo -e "Reiniciando Xray..."
if ! systemctl restart xray >>"$LOG_FILE" 2>&1 || ! _wait_xray_active; then
    echo -e "${TXT_RED}❌ Falha ao reiniciar Xray. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    _apply_config_perms
    systemctl restart xray >/dev/null 2>&1 || true
    journalctl -u xray -n 15 --no-pager 2>/dev/null || true
    echo -e "${TXT_YELLOW}Config revertido. Nenhum usuário foi removido.${RESET}"
    sleep 3; exit 1
fi

# --- PASSO 3: ATUALIZA O DB PRESERVANDO TODAS AS COLUNAS ---
tmp_db=$(mktemp "${USER_DB}.tmp.XXXXXX")
_TMP_FILES+=("$tmp_db")

awk -F'|' '
    NR==FNR { expired[$1]=1; next }
    NF > 0 {
        if ($1 in expired) {
            print " \033[1;31mRemovido DB:\033[0m " $1 > "/dev/stderr"
        } else {
            print $0
        }
    }
' "$expired_nicks_file" "$USER_DB" > "$tmp_db"

mv -f "$tmp_db" "$USER_DB"
_TMP_FILES=("${_TMP_FILES[@]/$tmp_db}")
chmod 600 "$USER_DB"
chown root:root "$USER_DB"

# --- PASSO 3b: LIMPA USAGE.DB E SESSION.DB ---
for aux_db in "$USAGE_DB" "$SESSION_DB"; do
    if [ -s "$aux_db" ] && [ -s "$expired_nicks_file" ]; then
        tmp_aux=$(mktemp "${aux_db}.tmp.XXXXXX")
        _TMP_FILES+=("$tmp_aux")
        awk -F'|' 'NR==FNR { expired[$1]=1; next } !($1 in expired) { print $0 }' "$expired_nicks_file" "$aux_db" > "$tmp_aux"
        mv -f "$tmp_aux" "$aux_db"
        _TMP_FILES=("${_TMP_FILES[@]/$tmp_aux}")
        chmod 600 "$aux_db"
    fi
done

# --- PASSO 3c: REMOVE USUÁRIOS LOCAIS (DROPBEAR / SOCKS5) ---
if [ -s "$expired_nicks_file" ]; then
    while IFS= read -r enick; do
        [ -n "$enick" ] || continue
        if id "$enick" &>/dev/null; then
            userdel -f "$enick" 2>/dev/null || true
        fi
    done < "$expired_nicks_file"
fi

# --- PASSO 4: LIMPA ARQUIVOS DE INFO ---
if [ -d "$CONN_INFO_DIR" ] && [ -s "$expired_nicks_file" ]; then
    while IFS= read -r nick; do
        [ -n "$nick" ] || continue
        local_info="${CONN_INFO_DIR}/${nick}.txt"
        if [ -f "$local_info" ]; then
            rm -f "$local_info"
            echo -e " ${TXT_CYAN}Arquivo removido:${RESET} ${nick}.txt"
        fi
    done < "$expired_nicks_file"
fi

echo ""
echo -e "${TXT_GREEN}✅ Limpeza concluída: ${count} usuário(s) removido(s).${RESET}"
read -rp "Enter para voltar..."
