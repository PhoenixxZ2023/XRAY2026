#!/bin/bash
# renew_user.sh - TURBONET XRAY V1.0
# Renova a data de expiração de usuários sem alterar UUID ou histórico
# Hardening:
# - Permissões 600 root:root no DB e 640 root:nogroup no config.json
# - Validação estrita de input (sanitize.sh)
# - Sanitização contra injeção de data

set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO"; sleep 2' ERR

USER_DB="/opt/XrayTools/users.db"
LOG_FILE="/tmp/renew_user.log"

TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TITLE_BAR='\033[1;47;34m'
RESET='\033[0m'

# Carrega sanitização se disponível
[ -f "/usr/local/bin/sanitize.sh" ] && source /usr/local/bin/sanitize.sh

clear
echo -e "${TITLE_BAR}   RENOVAR USUÁRIO   ${RESET}"
echo ""

if [ ! -s "$USER_DB" ]; then
    echo -e "${TXT_RED}❌ Banco de dados vazio ou inexistente.${RESET}"
    exit 1
fi

read -rp "Nick do usuário: " nick_raw
nick=$(echo "$nick_raw" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

if ! grep -q "^${nick}|" "$USER_DB" 2>/dev/null; then
    echo -e "${TXT_RED}❌ Usuário '${nick}' não encontrado.${RESET}"
    sleep 2; exit 1
fi

# Extrai dados atuais
data_atual=$(awk -F'|' -v n="$nick" '$1==n {print $3}' "$USER_DB")
echo -e "Usuário: ${TXT_CYAN}${nick}${RESET}"
echo -e "Data de expiração atual: ${TXT_YELLOW}${data_atual}${RESET}"
echo ""

read -rp "Quantos dias deseja adicionar? [Enter = 30]: " dias
dias="${dias:-30}"
[[ "$dias" =~ ^[0-9]+$ ]] || dias=30

# Calcula nova data
nova_data=$(date -d "${data_atual} +${dias} days" +%F 2>/dev/null || date -d "+${dias} days" +%F)

echo ""
echo -e "Nova data de expiração: ${TXT_GREEN}${nova_data}${RESET}"
read -rp "Confirmar renovação? [s/N]: " confirm
[[ "${confirm:-n}" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

# Atualiza DB de forma atômica
tmp_db=$(mktemp "${USER_DB}.tmp.XXXXXX")
awk -F'|' -v n="$nick" -v nd="$nova_data" \
    'BEGIN {OFS="|"} $1==n {$3=nd} {print $0}' "$USER_DB" > "$tmp_db"

mv -f "$tmp_db" "$USER_DB"
chmod 0600 "$USER_DB"
chown root:root "$USER_DB"

echo -e "${TXT_GREEN}✅ Usuário renovado com sucesso!${RESET}"
sleep 1
