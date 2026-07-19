#!/bin/bash
# renew_user.sh - TURBONET XRAY V1.2 (PRO)
# Módulo de Renovação Inteligente com Integração Total
#
# Funcionalidades:
# - Cálculo inteligente de datas (soma a partir de hoje se já estiver vencido)
# - Desbloqueio Automático (Remove LOCKED_ via API Hot Reload se suspenso)
# - Reset de franquia de dados opcional (Integração com limiterxray)
# - Desbloqueio nativo do SSH/SOCKS5 (passwd -u)
# - Atualização atômica segura (awk + mktemp)

set -Eeuo pipefail

# --- CLEANUP CENTRALIZADO ---
_TMP_FILES=()
_cleanup() {
    for f in "${_TMP_FILES[@]:-}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap '_cleanup' EXIT
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
USAGE_DB="/opt/XrayTools/usage.db"
SESSION_DB="/opt/XrayTools/session.db"
CONFIG_PATH="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

# --- DEPENDÊNCIAS E VERIFICAÇÕES ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${TXT_RED}❌ Execute como root!${RESET}"; exit 1
fi

if [ ! -s "$USER_DB" ]; then
    echo -e "${TXT_RED}❌ Banco de dados vazio ou inexistente.${RESET}"
    sleep 2; exit 1
fi

command -v jq >/dev/null 2>&1 || { echo -e "${TXT_RED}❌ 'jq' não instalado.${RESET}"; exit 1; }
command -v awk >/dev/null 2>&1 || { echo -e "${TXT_RED}❌ 'awk' não instalado.${RESET}"; exit 1; }

# Carrega sanitização se disponível
[ -f "/usr/local/bin/sanitize.sh" ] && source /usr/local/bin/sanitize.sh

# --- HELPERS DA API XRAY ---
_xray_api_port() {
    jq -r '.inbounds[]? | select(.tag=="api") | .port // empty' "$CONFIG_PATH" 2>/dev/null | head -1
}

_api_remove() {
    local email="$1"
    local p; p=$(_xray_api_port); [ -z "${p:-}" ] && return 1
    "$XRAY_BIN" api removeuser -server="127.0.0.1:${p}" \
        -inboundTag="inbound-turbonet" -email="$email" >/dev/null 2>&1
}

_api_add() {
    local email="$1" id="$2"
    local p; p=$(_xray_api_port); [ -z "${p:-}" ] && return 1
    local uj; uj=$(jq -n --arg id "$id" --arg e "$email" '{"id":$id,"email":$e,"level":0}')
    "$XRAY_BIN" api adduser -server="127.0.0.1:${p}" \
        -inboundTag="inbound-turbonet" -user="$uj" >/dev/null 2>&1
}

_apply_config_perms() {
    chmod 0640 "$CONFIG_PATH"
    chown root:nogroup "$CONFIG_PATH"
}

# --- INTERFACE ---
clear
echo -e "${TITLE_BAR}   RENOVAR USUÁRIO (V1.2 PRO)   ${RESET}"
echo ""

read -rp "Nick do usuário (0 para voltar): " nick_raw
[ "${nick_raw:-0}" = "0" ] || [ -z "${nick_raw:-}" ] && exit 0

nick=$(echo "$nick_raw" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

if ! grep -q "^${nick}|" "$USER_DB" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Usuário '${nick}' não encontrado no sistema.${RESET}"
    sleep 2; exit 1
fi

# Extrai os dados do DB
IFS='|' read -r db_nick db_uuid data_atual db_pass db_limit _rest < <(grep "^${nick}|" "$USER_DB" | head -1)

# Verifica se está suspenso/bloqueado no config.json
is_locked=false
if jq -e --arg lock "LOCKED_${nick}" '
    any(.inbounds[]? | select(.tag=="inbound-turbonet").settings.clients[]?; .email == $lock)
' "$CONFIG_PATH" >/dev/null 2>&1; then
    is_locked=true
fi

# Cálculo Inteligente de Data
hoje_ts=$(date +%s)
exp_ts=$(date -d "$data_atual" +%s 2>/dev/null || echo 0)

status_txt="${TXT_GREEN}ATIVO${RESET}"
data_base="$data_atual"

if [ "$is_locked" = true ]; then
    status_txt="${TXT_RED}BLOQUEADO / SUSPENSO${RESET}"
elif [ "$exp_ts" -lt "$hoje_ts" ]; then
    status_txt="${TXT_YELLOW}VENCIDO${RESET}"
    # Se está vencido, a nova data baseia-se em hoje, para não "comer" dias do cliente
    data_base=$(date +%F)
fi

echo -e "-----------------------------------------"
echo -e " 👤 Usuário: ${TXT_CYAN}${nick}${RESET}"
echo -e " 📅 Vencimento Atual: ${TXT_YELLOW}${data_atual}${RESET}"
echo -e " 🚥 Status: ${status_txt}"
echo -e "-----------------------------------------"
echo ""

read -rp "Quantos dias deseja adicionar? [Enter = 30]: " dias
dias="${dias:-30}"
[[ "$dias" =~ ^[0-9]+$ ]] || dias=30

nova_data=$(date -d "${data_base} +${dias} days" +%F 2>/dev/null || date -d "+${dias} days" +%F)

echo -e "Nova data de vencimento: ${TXT_GREEN}${nova_data}${RESET}"
echo ""

# Reset de Consumo de Dados (Integração Limiter)
reset_usage="n"
if [ -f "$USAGE_DB" ] && grep -q "^${nick}|" "$USAGE_DB" 2>/dev/null; then
    uso_bytes=$(awk -F'|' -v n="$nick" '$1==n {print $2}' "$USAGE_DB")
    uso_mb=$(( uso_bytes / 1048576 ))
    echo -e "Este usuário consumiu ${TXT_CYAN}${uso_mb} MB${RESET} na franquia atual."
    read -rp "Deseja ZERAR o consumo de dados (GB) dele? [S/n]: " reset_usage
    reset_usage=${reset_usage:-s}
fi

echo ""
read -rp "Confirmar renovação? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

echo ""
echo "Aplicando renovação..."

# 1. Atualiza Banco de Dados de Forma Atômica
tmp_db=$(mktemp "${USER_DB}.tmp.XXXXXX")
_TMP_FILES+=("$tmp_db")
awk -F'|' -v n="$nick" -v nd="$nova_data" 'BEGIN {OFS="|"} $1==n {$3=nd} {print $0}' "$USER_DB" > "$tmp_db"
mv -f "$tmp_db" "$USER_DB"
chmod 0600 "$USER_DB"
chown root:root "$USER_DB"

# 2. Desbloqueio Xray (Hot Reload) - Caso estivesse suspenso
if [ "$is_locked" = true ]; then
    echo "Identificado usuário suspenso. Restaurando acesso Xray..."
    
    cp -f "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    tmp_cfg=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
    _TMP_FILES+=("$tmp_cfg")
    
    jq --arg nick "$nick" --arg locked "LOCKED_$nick" --arg uuid "$db_uuid" '
        (.inbounds[] | select(.tag=="inbound-turbonet").settings.clients) |=
            map(if .email == $locked then .email = $nick | .id = $uuid else . end)
    ' "$CONFIG_PATH" > "$tmp_cfg"
    
    if jq empty "$tmp_cfg" 2>/dev/null; then
        mv -f "$tmp_cfg" "$CONFIG_PATH"
        _apply_config_perms
        
        if _api_remove "LOCKED_${nick}" && _api_add "$nick" "$db_uuid"; then
            echo -e "  ↳ ${TXT_GREEN}Acesso restaurado via API (Sem queda de conexões)${RESET}"
        else
            echo -e "  ↳ ${TXT_YELLOW}API indisponível, recarregando serviço...${RESET}"
            systemctl reload-or-restart xray >/dev/null 2>&1 || true
        fi
    else
        echo -e "  ↳ ${TXT_RED}Erro ao restaurar JSON. Acesso Xray não desbloqueado.${RESET}"
    fi
fi

# 3. Zera Consumo do Limiter (Opcional)
if [[ "${reset_usage}" =~ ^[Ss]$ ]]; then
    if [ -f "$USAGE_DB" ]; then
        tmp_usage=$(mktemp "${USAGE_DB}.tmp.XXXXXX")
        _TMP_FILES+=("$tmp_usage")
        awk -F'|' -v n="$nick" '$1!=n {print}' "$USAGE_DB" > "$tmp_usage"
        mv -f "$tmp_usage" "$USAGE_DB"
        chmod 0600 "$USAGE_DB"
    fi
    if [ -f "$SESSION_DB" ]; then
        tmp_session=$(mktemp "${SESSION_DB}.tmp.XXXXXX")
        _TMP_FILES+=("$tmp_session")
        awk -F'|' -v n="$nick" '$1!=n {print}' "$SESSION_DB" > "$tmp_session"
        mv -f "$tmp_session" "$SESSION_DB"
        chmod 0600 "$SESSION_DB"
    fi
    echo -e "  ↳ ${TXT_GREEN}Consumo de dados zerado.${RESET}"
fi

# 4. Desbloqueio SSH/SOCKS5 Local (Garante que senhas Linux voltem a funcionar)
if id "$nick" &>/dev/null; then
    passwd -u "$nick" 2>/dev/null || true
    echo -e "  ↳ ${TXT_GREEN}Acesso SSH/SOCKS5 local habilitado.${RESET}"
fi

# 5. Atualiza Arquivo de Conexão Individual
user_file="/opt/XrayTools/users/${nick}.txt"
if [ -f "$user_file" ]; then
    sed -i "s/^EXPIRA=.*/EXPIRA=${nova_data}/" "$user_file"
fi

echo ""
echo -e "${TXT_GREEN}✅ Usuário '${nick}' renovado com sucesso!${RESET}"
echo -e "Nova Expiração: ${TXT_CYAN}${nova_data}${RESET} (+${dias} dias)"
echo "-----------------------------------------"
read -rp "Pressione Enter para voltar ao menu..."
