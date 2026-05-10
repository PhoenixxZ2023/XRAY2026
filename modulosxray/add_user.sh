#!/bin/bash
# add_user.sh - TURBONET XRAY V1.1
# Correções aplicadas:
#   - Adicionado campo SENHA na criação de usuário
#   - Formato do users.db: nick|uuid|expiry|password|conn_limit
#   - Validação de senha (mín 4 caracteres)
#   - Limite de conexões (padrão ilimitado = 0)
#   - Compatível com CheckUser API (/checkuserxray)
#
# Versão V1.0 (original):
#   - chmod 777 → 640 root:nogroup em todos os pontos
#   - trap duplo eliminado — _cleanup() centralizado
#   - Verificação de xray ativo com retry de até 5s
#   - Duplicidade case-insensitive — nome normalizado para minúsculas

set -Eeuo pipefail

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"
PRESET_FILE="/usr/local/etc/xray/preset.json"
CONN_INFO_DIR="/opt/XrayTools/users"
LOG_FILE="/tmp/add_user.log"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

export DEBIAN_FRONTEND=noninteractive

# --- CLEANUP CENTRALIZADO ---
_tmp_cfg=""
_cleanup() {
    rm -f "$_tmp_cfg"
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

# --- PERMISSÕES DO CONFIG ---
_apply_config_perms() {
    chmod 660 "$CONFIG_PATH"
    chown root:nogroup "$CONFIG_PATH"
}

# --- DETECÇÃO DE DISTRO ---
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

# --- GERAÇÃO DE SENHA ALEATÓRIA ---
generate_password() {
    local length="${1:-8}"
    # Gera senha alfanumérica com caracteres seguros
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
}

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
    if [[ ! "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo -e "${TXT_RED}❌ Falha ao gerar UUID válido.${RESET}" >&2
        return 1
    fi
    echo "$u"
}

# --- GERAÇÃO DO LINK VLESS ---
generate_link() {
    local uuid="$1" nick="$2"

    if [ ! -f "$PRESET_FILE" ]; then
        echo -e "${TXT_YELLOW}⚠  preset.json não encontrado.${RESET}" >&2
        return
    fi

    jq empty "$PRESET_FILE" 2>/dev/null || return

    local network port domain tls
    network=$(jq -r '.network // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    port=$(jq -r '.port // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    domain=$(jq -r '.domain // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    tls=$(jq -r '.tls // "false"' "$PRESET_FILE" 2>/dev/null || echo "false")

    [ -z "$network" ] || [ -z "$port" ] || [ -z "$domain" ] && return

    local sec="none"
    [ "$tls" = "true" ] && sec="tls"

    local link=""
    case "$network" in
        grpc)   link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=gRPC&sni=${domain}#${nick}" ;;
        ws)     link="vless://${uuid}@${domain}:${port}?path=%2F&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#${nick}" ;;
        xhttp)  link="vless://${uuid}@${domain}:${port}?mode=auto&path=%2F&security=${sec}&encryption=none&host=${domain}&type=xhttp&sni=${domain}#${nick}" ;;
        vision) link="vless://${uuid}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#${nick}" ;;
        *)      link="vless://${uuid}@${domain}:${port}?security=${sec}&encryption=none&type=tcp&sni=${domain}#${nick}" ;;
    esac
    echo "$link"
}

# --- VERIFICAÇÃO DE XRAY ATIVO ---
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
touch "$USER_DB"

if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ Config não encontrada: $CONFIG_PATH${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Config JSON inválido.${RESET}"
    sleep 2; exit 1
fi
if ! jq -e '.inbounds[]? | select(.tag=="inbound-turbonet")' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ inbound-turbonet não encontrado.${RESET}"
    sleep 2; exit 1
fi

# --- INTERFACE ---
clear
echo -e "${TITLE_BAR}   CRIAR NOVO USUÁRIO   ${RESET}"
echo ""
echo "Regras do nome:"
echo " - Entre 5 e 9 caracteres"
echo " - Apenas letras e números (sem espaços)"
echo ""
read -rp "Nome do usuário (0 para voltar): " raw_nick

[ "${raw_nick:-0}" = "0" ] || [ -z "${raw_nick:-}" ] && exit 0

if ! [[ "$raw_nick" =~ ^[a-zA-Z0-9]{5,9}$ ]]; then
    echo -e "${TXT_RED}❌ Nome inválido.${RESET}"
    sleep 2; exit 1
fi

nick=$(echo "$raw_nick" | tr '[:upper:]' '[:lower:]')

# Duplicidade no DB
if grep -q "^${nick}|" "$USER_DB" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Usuário '${nick}' já existe.${RESET}"
    sleep 2; exit 1
fi

# Duplicidade no config.json
if jq -e --arg nick "$nick" \
    '.inbounds[]? | select(.tag=="inbound-turbonet") | .settings.clients[]? | select(.email==$nick)' \
    "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Usuário '${nick}' já existe no config.json.${RESET}"
    sleep 2; exit 1
fi

# --- SENHA ---
echo ""
echo "Senha para o usuário:"
echo " - Mínimo 4 caracteres"
echo " - Será usada no CheckUser (apps como Conecta4G)"
echo ""
read -rp "Senha [Enter = gerar automaticamente]: " password

if [ -z "$password" ]; then
    password=$(generate_password 8)
    echo -e "${TXT_CYAN}Senha gerada: ${password}${RESET}"
fi

if [ ${#password} -lt 4 ]; then
    echo -e "${TXT_RED}❌ Senha muito curta (mín 4 caracteres).${RESET}"
    sleep 2; exit 1
fi

# Remove caracteres perigosos da senha
password=$(echo "$password" | tr -cd 'a-zA-Z0-9@#$%&*+-=')
if [ -z "$password" ]; then
    echo -e "${TXT_RED}❌ Senha contém apenas caracteres inválidos.${RESET}"
    sleep 2; exit 1
fi

# --- LIMITE DE CONEXÕES ---
echo ""
echo "Limite de conexões simultâneas:"
echo "   [0] Ilimitado (padrão)"
echo "   [1] Apenas 1 dispositivo"
echo "   [2] Até 2 dispositivos"
echo "   [n] Número específico"
read -rp "Limite [Enter = 0 = ilimitado]: " conn_limit

[ -z "$conn_limit" ] && conn_limit=0

if ! [[ "$conn_limit" =~ ^[0-9]+$ ]]; then
    conn_limit=0
fi

if [ "$conn_limit" -gt 100 ]; then
    conn_limit=100  # Máximo razoável
fi

# --- VALIDADE ---
read -rp "Dias de validade [Enter = 30]: " days
[ -z "${days:-}" ] && days=30
[[ "$days" =~ ^[0-9]+$ ]] || days=30
(( days < 1 || days > 3650 )) && days=30

# --- GERAÇÃO ---
uuid=$(generate_uuid) || { sleep 2; exit 1; }
expiry="$(date -d "+${days} days" +%F)"

# --- APLICA NO CONFIG (atômico) ---
_tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

jq --arg uuid "$uuid" --arg nick "$nick" '
  (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
    (if type == "array" then . else [] end)
  |
  (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) +=
    [{"id": $uuid, "email": $nick, "level": 0}]
' "$CONFIG_PATH" > "$_tmp_cfg"

if ! jq empty "$_tmp_cfg" 2>/dev/null; then
    echo -e "${TXT_RED}❌ jq gerou JSON inválido.${RESET}"
    sleep 2; exit 1
fi

cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
mv -f "$_tmp_cfg" "$CONFIG_PATH"
_tmp_cfg=""
_apply_config_perms

# --- HOT RELOAD ---
_xray_api_port() {
    jq -r '.inbounds[]? | select(.tag=="api") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1
}
_hotreload_add() {
    local api_port; api_port=$(_xray_api_port)
    [ -z "${api_port:-}" ] && return 1
    local user_json
    user_json=$(jq -n --arg id "$uuid" --arg email "$nick" '{"id":$id,"email":$email,"level":0}')
    /usr/local/bin/xray api adduser -server="127.0.0.1:${api_port}" -inboundTag="inbound-turbonet" -user="$user_json" >/dev/null 2>&1
}

if _hotreload_add; then
    echo -e "${TXT_GREEN}Usuário aplicado via API.${RESET}"
else
    echo -e "${TXT_YELLOW}API indisponível — recarregando...${RESET}"
    if ! systemctl try-reload-or-restart xray >/dev/null 2>&1 && ! systemctl restart xray >/dev/null 2>&1; then
        echo -e "${TXT_RED}❌ Falha ao recarregar Xray. Revertendo...${RESET}"
        mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        _apply_config_perms
        echo -e "${TXT_YELLOW}Config revertido.${RESET}"
        sleep 3; exit 1
    fi
    if ! _wait_xray_active; then
        echo -e "${TXT_RED}❌ Xray não ficou ativo. Revertendo...${RESET}"
        mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        _apply_config_perms
        sleep 2; exit 1
    fi
fi

# --- GRAVA NO DB (V1.1: com senha e limite) ---
# Formato: nick|uuid|expiry|password|conn_limit
echo "${nick}|${uuid}|${expiry}|${password}|${conn_limit}" >> "$USER_DB"

link=$(generate_link "$uuid" "$nick")

# Arquivo individual
user_file="${CONN_INFO_DIR}/${nick}.txt"
{
    echo "# TURBONET XRAY - Usuário: ${nick}"
    echo "# Criado em: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "NOME=${nick}"
    echo "UUID=${uuid}"
    echo "SENHA=${password}"
    echo "EXPIRA=${expiry}"
    echo "LIMIT_CONN=${conn_limit}"
    [ -n "$link" ] && echo "LINK=${link}"
} > "$user_file"
chmod 0600 "$user_file"

# --- RESULTADO ---
clear
echo -e "${TXT_GREEN}✅ Usuário criado com sucesso!${RESET}"
echo "-----------------------------------------"
echo -e " 👤 Nome:   ${TXT_CYAN}${nick}${RESET}"
echo -e " 🔑 UUID:   ${TXT_YELLOW}${uuid}${RESET}"
echo -e " 🔐 Senha:  ${TXT_YELLOW}${password}${RESET}"
echo -e " 📅 Expira: ${expiry} (${days} dias)"
echo -e " 🔢 Limite: ${conn_limit} conexão(ões)"
echo "-----------------------------------------"
echo ""
echo -e "${TXT_CYAN}⚠ Anote a senha — não será exibida novamente!${RESET}"
read -rp "Enter para voltar..."
