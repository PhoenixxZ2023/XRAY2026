#!/bin/bash
# add_user.sh - TURBONET XRAY V1.4 (PRO)
# Correções aplicadas:
#   - Detecção dinâmica do usuário/grupo do xray.service (_detect_xray_owner)
#   - Permissões 750/640 root:$XRAY_GROUP aplicadas no diretório e no config.json
#   - Validação com `xray run -test` sob o usuário do serviço antes de reiniciar
#   - Substituído try-reload-or-restart por restart direto (evita falha silenciosa quando inativo)
#   - Suporte completo a Trojan (password), Vision (xtls-rprx-vision), HTTPUpgrade e H2
#   - Bloqueio do caractere '|' na senha para proteger a estrutura do users.db

set -Eeuo pipefail

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"
PRESET_FILE="/usr/local/etc/xray/preset.json"
CONN_INFO_DIR="/opt/XrayTools/users"
LOG_FILE="/tmp/add_user.log"

XRAY_USER="nobody"
XRAY_GROUP="nogroup"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
RESET='\033[0m'
TITLE_BAR='\033[1;47;34m'

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

    if [ -f "$PRESET_FILE" ]; then
        chown "root:${XRAY_GROUP}" "$PRESET_FILE"
        chmod 0640 "$PRESET_FILE"
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
            if [ "$_APT_UPDATED" -eq 0 ]; then
                apt-get update -y >>"$LOG_FILE" 2>&1 || true
                _APT_UPDATED=1
            fi
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
            ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
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

generate_trojan_password() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 16
    else
        tr -dc 'a-f0-9' < /dev/urandom | head -c 32
    fi
}

# --- GERAÇÃO DO LINK A PARTIR DO PRESET ---
generate_link() {
    local cred="$1" nick="$2"

    if [ ! -f "$PRESET_FILE" ]; then
        echo -e "${TXT_YELLOW}⚠  preset.json não encontrado — configure o Xray primeiro (opção 04 no menu).${RESET}" >&2
        echo ""
        return
    fi

    jq empty "$PRESET_FILE" 2>/dev/null || {
        echo -e "${TXT_YELLOW}⚠  preset.json com JSON inválido — link não gerado.${RESET}" >&2
        echo ""
        return
    }

    local network port domain tls
    network=$(jq -r '.network // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    port=$(jq -r    '.port    // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    domain=$(jq -r  '.domain  // ""' "$PRESET_FILE" 2>/dev/null || echo "")
    tls=$(jq -r     '.tls     // "false"' "$PRESET_FILE" 2>/dev/null || echo "false")

    [ -z "$network" ] || [ -z "$port" ] || [ -z "$domain" ] && {
        echo -e "${TXT_YELLOW}⚠  preset.json incompleto — campos network/port/domain ausentes.${RESET}" >&2
        echo ""
        return
    }

    local sec="none"
    [ "$tls" = "true" ] && sec="tls"

    local link=""
    case "$network" in
        grpc)        link="vless://${cred}@${domain}:${port}?security=${sec}&encryption=none&type=grpc&serviceName=gRPC&sni=${domain}#${nick}" ;;
        ws)          link="vless://${cred}@${domain}:${port}?path=%2F&security=${sec}&encryption=none&host=${domain}&type=ws&sni=${domain}#${nick}" ;;
        xhttp)       link="vless://${cred}@${domain}:${port}?mode=auto&path=%2F&security=${sec}&encryption=none&host=${domain}&type=xhttp&sni=${domain}#${nick}" ;;
        vision)      link="vless://${cred}@${domain}:${port}?security=tls&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${domain}#${nick}" ;;
        httpupgrade) link="vless://${cred}@${domain}:${port}?path=%2F&security=${sec}&encryption=none&host=${domain}&type=httpupgrade&sni=${domain}#${nick}" ;;
        h2)          link="vless://${cred}@${domain}:${port}?path=%2F&security=tls&encryption=none&host=${domain}&type=h2&sni=${domain}#${nick}" ;;
        trojan)      link="trojan://${cred}@${domain}:${port}?security=tls&sni=${domain}&type=tcp#${nick}" ;;
        *)           link="vless://${cred}@${domain}:${port}?security=${sec}&encryption=none&type=tcp&sni=${domain}#${nick}" ;;
    esac
    echo "$link"
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
mkdir -p "$(dirname "$USER_DB")" "$CONN_INFO_DIR"
touch "$USER_DB"
chmod 0600 "$USER_DB"

if [ ! -s "$CONFIG_PATH" ]; then
    echo -e "${TXT_RED}❌ Config não encontrada: $CONFIG_PATH${RESET}"
    sleep 2; exit 1
fi
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Config JSON inválido: $CONFIG_PATH${RESET}"
    sleep 2; exit 1
fi
if ! jq -e '.inbounds[]? | select(.tag=="inbound-turbonet")' "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ inbound-turbonet não encontrado no config.${RESET}"
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
    echo -e "${TXT_RED}❌ Nome inválido. Use de 5 a 9 letras/números.${RESET}"
    sleep 2; exit 1
fi

nick=$(echo "$raw_nick" | tr '[:upper:]' '[:lower:]')

if grep -q "^${nick}|" "$USER_DB" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Usuário '${nick}' já existe no banco de dados.${RESET}"
    sleep 2; exit 1
fi

if jq -e --arg nick "$nick" \
    '.inbounds[]? | select(.tag=="inbound-turbonet") | .settings.clients[]? | select(.email==$nick)' \
    "$CONFIG_PATH" >/dev/null 2>&1; then
    echo -e "${TXT_RED}❌ Usuário '${nick}' já existe no config.json.${RESET}"
    sleep 2; exit 1
fi

read -rp "Dias de validade [Enter = 30]: " days
[ -z "${days:-}" ] && days=30
[[ "$days" =~ ^[0-9]+$ ]] || days=30
(( days < 1 || days > 3650 )) && days=30

echo ""
echo -e " ${TXT_CYAN}Senha para SSH, SOCKS5 e CheckUser${RESET}:"
read -rp " Senha [Enter = gerar automaticamente]: " user_pass
if [ -z "${user_pass:-}" ]; then
    user_pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 8)
    echo -e " Senha gerada: ${TXT_YELLOW}${user_pass}${RESET}"
fi
user_pass=$(echo "$user_pass" | tr -d '[:space:][:cntrl:]|')
if [ -z "$user_pass" ]; then
    echo -e "${TXT_RED}❌ Senha inválida.${RESET}"
    sleep 2; exit 1
fi

echo ""
read -rp " Limite de conexões [Enter = 0 = ilimitado]: " conn_limit
[ -z "${conn_limit:-}" ] && conn_limit=0
[[ "$conn_limit" =~ ^[0-9]+$ ]] || conn_limit=0

# --- DETECTA PROTOCOLO / FLOW DO INBOUND ---
inbound_proto=$(jq -r '.inbounds[]? | select(.tag=="inbound-turbonet") | .protocol // "vless"' "$CONFIG_PATH" 2>/dev/null | head -1)
preset_net=$(jq -r '.network // ""' "$PRESET_FILE" 2>/dev/null || echo "")

if [ "$inbound_proto" = "trojan" ]; then
    uuid=$(generate_trojan_password) || { sleep 2; exit 1; }
else
    uuid=$(generate_uuid) || { sleep 2; exit 1; }
fi

expiry="$(date -d "+${days} days" +%F)"

# --- APLICA NO CONFIG DO XRAY ---
_tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")

if [ "$inbound_proto" = "trojan" ]; then
    jq --arg pwd "$uuid" --arg nick "$nick" '
      (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
        (if type == "array" then . else [] end)
      |
      (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) +=
        [{"password": $pwd, "email": $nick, "level": 0}]
    ' "$CONFIG_PATH" > "$_tmp_cfg"
elif [ "$preset_net" = "vision" ]; then
    jq --arg uuid "$uuid" --arg nick "$nick" '
      (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
        (if type == "array" then . else [] end)
      |
      (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) +=
        [{"id": $uuid, "email": $nick, "level": 0, "flow": "xtls-rprx-vision"}]
    ' "$CONFIG_PATH" > "$_tmp_cfg"
else
    jq --arg uuid "$uuid" --arg nick "$nick" '
      (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
        (if type == "array" then . else [] end)
      |
      (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) +=
        [{"id": $uuid, "email": $nick, "level": 0}]
    ' "$CONFIG_PATH" > "$_tmp_cfg"
fi

if ! jq empty "$_tmp_cfg" 2>/dev/null; then
    echo -e "${TXT_RED}❌ jq gerou JSON inválido. Config não alterado.${RESET}"
    sleep 2; exit 1
fi

cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
mv -f "$_tmp_cfg" "$CONFIG_PATH"
_tmp_cfg=""
_apply_config_perms

# --- VALIDA E REINICIA O XRAY ---
if ! _test_xray_config "$CONFIG_PATH" >>"$LOG_FILE" 2>&1; then
    echo -e "${TXT_RED}❌ Falha na validação do config.json pelo Xray. Revertendo...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    _apply_config_perms
    tail -n 10 "$LOG_FILE" 2>/dev/null || true
    sleep 3; exit 1
fi

echo -e "${TXT_YELLOW}Aplicando usuário no Xray...${RESET}"
if ! systemctl restart xray >>"$LOG_FILE" 2>&1 || ! _wait_xray_active; then
    echo -e "${TXT_RED}❌ Falha ao iniciar/recarregar Xray. Revertendo config...${RESET}"
    mv -f "${CONFIG_PATH}.bak" "$CONFIG_PATH"
    _apply_config_perms
    systemctl restart xray >/dev/null 2>&1 || true
    echo -e "${TXT_YELLOW}Config revertido. Usuário NÃO criado.${RESET}"
    journalctl -u xray -n 15 --no-pager 2>/dev/null || true
    sleep 3; exit 1
fi

# --- GRAVA NO DB ---
echo "${nick}|${uuid}|${expiry}|${user_pass}|${conn_limit}" >> "$USER_DB"
chmod 0600 "$USER_DB"

link=$(generate_link "$uuid" "$nick")

user_file="${CONN_INFO_DIR}/${nick}.txt"
{
    echo "# TURBONET XRAY - Usuário: ${nick}"
    echo "# Criado em: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "NOME=${nick}"
    echo "UUID=${uuid}"
    echo "EXPIRA=${expiry}"
    [ -n "$link" ] && echo "LINK=${link}"
} > "$user_file"
chmod 0600 "$user_file"

# --- INTEGRAÇÃO SSH/SOCKS5: CRIAR USUÁRIO NO LINUX AUTOMATICAMENTE ---
if systemctl is-active --quiet turbonet-dropbear 2>/dev/null || systemctl is-active --quiet turbonet-socks5 2>/dev/null; then
    if ! id "$nick" &>/dev/null; then
        useradd -M -s /bin/false "$nick" 2>/dev/null || true
    fi
    echo "${nick}:${user_pass}" | chpasswd 2>/dev/null || true
    echo -e "${TXT_GREEN}✅ Conta local configurada (Acesso liberado ao SSH e SOCKS5).${RESET}"
fi

# --- RESULTADO ---
clear
echo -e "${TXT_GREEN}✅ Usuário criado com sucesso!${RESET}"
echo "-----------------------------------------"
echo -e " 👤 Nome:     ${TXT_CYAN}${nick}${RESET}"
echo -e " 🔑 Credenc.: ${TXT_YELLOW}${uuid}${RESET}"
echo -e " 🔐 Senha:    ${TXT_YELLOW}${user_pass}${RESET}"
echo -e " 📅 Expira:   ${expiry} (${days} dias)"
echo -e " 🔗 Limite:   ${conn_limit} conexões simultâneas"
if [ -n "$link" ]; then
    echo "-----------------------------------------"
    echo -e " 🌐 Link:\n${TXT_BLUE}${link}${RESET}"
fi
echo "-----------------------------------------"
read -rp "Enter para voltar..."
