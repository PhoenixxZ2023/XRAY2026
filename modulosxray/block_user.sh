#!/bin/bash
# block_user.sh - TURBONET XRAY V1.1
# Correções aplicadas:
#   - Detecção dinâmica do usuário/grupo do xray.service (_detect_xray_owner)
#   - Permissões 750/640 root:$XRAY_GROUP aplicadas no diretório e no config.json
#   - Validação com `xray run -test` sob o usuário do serviço antes de reiniciar
#   - Substituído try-reload-or-restart por restart direto no fallback
#   - Suporte a Trojan (invalida .password além de .id no modo VLESS/VMess)
#   - Bloqueio da conta Linux também quando turbonet-socks5 estiver ativo

set -Eeuo pipefail

# --- CLEANUP CENTRALIZADO ---
_tmp_cfg=""
_cleanup() {
    [ -n "${_tmp_cfg:-}" ] && rm -f "$_tmp_cfg"
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
LOG_FILE="/tmp/block_user.log"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

TXT_RED='\033[1;31m'
TXT_GREEN='\033[1;32m'
TXT_YELLOW='\033[1;33m'
TXT_CYAN='\033[1;36m'
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

# --- UUID COM FALLBACK E VALIDAÇÃO ---
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
        echo -e "${TXT_RED}❌ Falha ao gerar UUID válido.${RESET}" >&2
        return 1
    }
    echo "$u"
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
echo -e "${TXT_RED}🔒 BLOQUEAR USUÁRIO (SUSPENDER)${RESET}"
echo "Impede conexão, mas mantém o cadastro."
echo ""

if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ config.json não encontrado.${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ config.json inválido (JSON corrompido).${RESET}"
    sleep 2; exit 1
fi

echo -e "${TXT_CYAN}--- Usuários Ativos ---${RESET}"
active_list=$(jq -r '
    .inbounds[]? | select(.tag=="inbound-turbonet")
    | .settings.clients[]?
    | select(.email? and (.email | startswith("LOCKED_") | not))
    | .email
' "$CONFIG_PATH" 2>/dev/null || true)

if [ -z "${active_list:-}" ]; then
    echo " Nenhum usuário ativo no momento."
else
    echo "$active_list" | awk 'NF{print " • " $0}'
fi
echo "-----------------------"
echo ""

read -rp "Usuário para suspender (0 para voltar): " user_block
[ "${user_block:-0}" = "0" ] || [ -z "${user_block:-}" ] && exit 0

if ! validate_nick "$user_block"; then
    echo -e "${TXT_RED}❌ Nick inválido. Use 5-9 letras/números.${RESET}"
    sleep 2; exit 1
fi

user_block=$(echo "$user_block" | tr '[:upper:]' '[:lower:]')

if [ ! -f "$USER_DB" ] || \
   ! awk -F'|' -v u="$user_block" '$1==u{found=1} END{exit found?0:1}' "$USER_DB" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Usuário não encontrado no banco de dados.${RESET}"
    sleep 2; exit 1
fi

if ! jq -e --arg nick "$user_block" '
    any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?;
        .email == $nick)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_YELLOW}⚠  Usuário '${user_block}' não encontrado no config.json.${RESET}"
    echo -e "   DB e config estão dessincronizados — verifique com lista_users.sh."
    sleep 3; exit 1
fi

if jq -e --arg lock "LOCKED_${user_block}" '
    any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?; .email == $lock)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_YELLOW}⚠  Usuário '${user_block}' já está bloqueado.${RESET}"
    sleep 2; exit 0
fi

# Confirmação explícita
echo ""
echo -e "${TXT_YELLOW}⚠  Isso suspenderá o acesso de '${user_block}' imediatamente.${RESET}"
read -rp "Confirmar bloqueio? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; sleep 1; exit 0; }

echo "Suspendendo acesso..."

FAKE_UUID=$(generate_uuid) || { sleep 2; exit 1; }
FAKE_PASS=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32)

cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"

_tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

jq --arg nick     "$user_block" \
   --arg locked   "LOCKED_$user_block" \
   --arg fake     "$FAKE_UUID" \
   --arg fakepass "$FAKE_PASS" '
    (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
        (if type == "array" then . else [] end)
    |
    (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
        map(if .email == $nick then
            .email = $locked
            | (if has("password") then .password = $fakepass else . end)
            | (if has("id") then .id = $fake else . end)
        else . end)
' "$CONFIG_PATH" > "$_tmp_cfg" 2>>"$LOG_FILE"

if ! jq empty "$_tmp_cfg" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Erro interno: JSON inválido gerado. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

if ! jq -e --arg locked "LOCKED_${user_block}" '
    any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?;
        .email == $locked)
' "$_tmp_cfg" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Verificação pós-geração falhou: LOCKED_ não encontrado no JSON.${RESET}"
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

# Aplica suspensão (remove sessão ativa via API e reinicia para efetivar o LOCKED_)
_api_remove "$user_block" 2>/dev/null || true
_fallback_reload || exit 1

# Bloquear conta local automaticamente (Dropbear / SOCKS5)
if id "$user_block" &>/dev/null; then
    passwd -l "$user_block" 2>/dev/null || true
    pkill -KILL -u "$user_block" 2>/dev/null || true
fi

echo ""
echo -e "${TXT_GREEN}✅ Usuário '${user_block}' suspenso com sucesso!${RESET}"
echo -e " Credencial substituída e prefixo ${TXT_YELLOW}LOCKED_${RESET} adicionado."
echo -e " Para reativar, use a opção ${TXT_CYAN}Desbloquear Usuário${RESET} no menu."
sleep 2
